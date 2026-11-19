-- CPA-SmartBank 第一階段：Row Level Security
--
-- 角色（public.profiles.role）：
--   admin    ：全部權限，唯一可發佈批次、管理考試與使用者角色
--   reviewer ：可上傳 PDF、檢視預覽、編輯暫存資料與處理異常，不可發佈
--   student  ：只能讀取「已公開考試」的正式題庫與答案
--   anon / 無 profile：完全沒有權限
-- 已發佈批次（status = 'published'）對一般角色唯讀；正式題庫只能由 admin 修改，
-- 或經 publish_import_batch()（security definer）寫入。

-- ---------------------------------------------------------------------------
-- 角色輔助函式（security definer 以避免 profiles 的 RLS 遞迴）
-- ---------------------------------------------------------------------------
create function public.current_app_role() returns public.app_role
language sql
stable
security definer
set search_path = ''
as $$
  select p.role from public.profiles p where p.id = (select auth.uid());
$$;

create function public.is_admin() returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select p.role = 'admin' from public.profiles p where p.id = (select auth.uid())), false);
$$;

create function public.is_staff() returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select p.role in ('admin', 'reviewer') from public.profiles p where p.id = (select auth.uid())), false);
$$;

-- 批次是否仍可編輯（尚未發佈）
create function public.batch_is_open(p_batch uuid) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.import_batches b where b.id = p_batch and b.status <> 'published'
  );
$$;

revoke all on function public.current_app_role(), public.is_admin(), public.is_staff(), public.batch_is_open(uuid) from public, anon;
grant execute on function public.current_app_role(), public.is_admin(), public.is_staff(), public.batch_is_open(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 權限：anon 完全無權；authenticated 的實際範圍由 RLS 決定
-- ---------------------------------------------------------------------------
revoke all on public.profiles, public.exams, public.import_batches, public.source_documents,
  public.staged_questions, public.staged_answers, public.import_anomalies,
  public.questions, public.question_answers from anon;

grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.exams, public.import_batches, public.source_documents,
  public.staged_questions, public.staged_answers, public.import_anomalies,
  public.questions, public.question_answers to authenticated;

alter table public.profiles enable row level security;
alter table public.exams enable row level security;
alter table public.import_batches enable row level security;
alter table public.source_documents enable row level security;
alter table public.staged_questions enable row level security;
alter table public.staged_answers enable row level security;
alter table public.import_anomalies enable row level security;
alter table public.questions enable row level security;
alter table public.question_answers enable row level security;

-- ---------------------------------------------------------------------------
-- profiles：自己或 admin 可讀；只有 admin 可改（含角色）；使用者無法自行提權
-- ---------------------------------------------------------------------------
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or public.is_admin());
create policy profiles_update_admin on public.profiles for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------------------
-- exams：學生只看已公開；staff 全看；只有 admin 寫入
-- ---------------------------------------------------------------------------
create policy exams_select on public.exams for select to authenticated
  using (is_published or public.is_staff());
create policy exams_insert on public.exams for insert to authenticated
  with check (public.is_admin());
create policy exams_update on public.exams for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy exams_delete on public.exams for delete to authenticated
  using (public.is_admin());

-- ---------------------------------------------------------------------------
-- import_batches：staff 可建立/編輯未發佈批次；不得直接把 status 改成 published
-- ---------------------------------------------------------------------------
create policy import_batches_select on public.import_batches for select to authenticated
  using (public.is_staff());
create policy import_batches_insert on public.import_batches for insert to authenticated
  with check (public.is_staff() and status <> 'published' and created_by = (select auth.uid()));
create policy import_batches_update on public.import_batches for update to authenticated
  using (public.is_staff() and status <> 'published')
  with check (public.is_staff() and status <> 'published');
create policy import_batches_delete on public.import_batches for delete to authenticated
  using (public.is_admin() and status <> 'published');

-- ---------------------------------------------------------------------------
-- source_documents：staff 可讀、可在未發佈批次新增；僅 admin 可刪未發佈批次的文件
-- ---------------------------------------------------------------------------
create policy source_documents_select on public.source_documents for select to authenticated
  using (public.is_staff());
create policy source_documents_insert on public.source_documents for insert to authenticated
  with check (public.is_staff() and public.batch_is_open(batch_id) and uploaded_by = (select auth.uid()));
create policy source_documents_delete on public.source_documents for delete to authenticated
  using (public.is_admin() and public.batch_is_open(batch_id));

-- ---------------------------------------------------------------------------
-- staged_* / import_anomalies：staff 在未發佈批次可讀寫
-- ---------------------------------------------------------------------------
create policy staged_questions_select on public.staged_questions for select to authenticated
  using (public.is_staff());
create policy staged_questions_write on public.staged_questions for all to authenticated
  using (public.is_staff() and public.batch_is_open(batch_id))
  with check (public.is_staff() and public.batch_is_open(batch_id));

create policy staged_answers_select on public.staged_answers for select to authenticated
  using (public.is_staff());
create policy staged_answers_write on public.staged_answers for all to authenticated
  using (public.is_staff() and public.batch_is_open(batch_id))
  with check (public.is_staff() and public.batch_is_open(batch_id));

create policy import_anomalies_select on public.import_anomalies for select to authenticated
  using (public.is_staff());
create policy import_anomalies_write on public.import_anomalies for all to authenticated
  using (public.is_staff() and public.batch_is_open(batch_id))
  with check (public.is_staff() and public.batch_is_open(batch_id));

-- ---------------------------------------------------------------------------
-- 正式題庫：學生只讀已公開考試；寫入僅 admin（或 publish_import_batch）
-- ---------------------------------------------------------------------------
create policy questions_select on public.questions for select to authenticated
  using (
    public.is_staff()
    or exists (select 1 from public.exams e where e.id = questions.exam_id and e.is_published)
  );
create policy questions_write on public.questions for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy question_answers_select on public.question_answers for select to authenticated
  using (
    public.is_staff()
    or exists (
      select 1 from public.questions q
      join public.exams e on e.id = q.exam_id
      where q.id = question_answers.question_id and e.is_published
    )
  );
create policy question_answers_write on public.question_answers for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
