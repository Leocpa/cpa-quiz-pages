-- CPA-SmartBank：統一題庫（bank_questions）
--
-- 兩種來源，放在同一張表，練習時可混合：
--   past_exam：歷屆考題，保留「原始題目」。必須指向 exams（年度／考試／科目）、題號與來源檔案頁碼。
--   custom   ：自訂題目（主要給法規科目），不屬於任何考試年度，以「科目＋主題＋法條」分類。
--
-- 解析時引用的法條不複製文字，只記 (法規代碼, 條號)，顯示時從 law_articles 取最新條文，
-- 法規修正後重新匯入法規資料，題目看到的就是現行條文。
--
-- 權限：
--   admin    ：全部（含發佈、修改歷屆題）
--   reviewer ：只能新增與修改「自己建立的自訂草稿」，不能發佈、不能動歷屆題
--   student  ：只讀已發佈題目（歷屆題另需其考試已公開）
--   anon     ：無

create type public.bank_origin as enum ('past_exam', 'custom');
create type public.bank_status as enum ('draft', 'published');

-- ---------------------------------------------------------------------------
-- subjects：科目目錄。is_law = 法規科目（自訂題與法條連結的主要使用者）
-- ---------------------------------------------------------------------------
create table public.subjects (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(btrim(name)) > 0),
  is_law boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

insert into public.subjects (name, is_law, sort_order) values
  ('公司法與證券交易法', true, 10),
  ('稅務法規', true, 20),
  ('會計師法與職業道德', true, 30)
on conflict (name) do nothing;

-- ---------------------------------------------------------------------------
-- bank_questions
-- ---------------------------------------------------------------------------
create table public.bank_questions (
  id uuid primary key default gen_random_uuid(),
  origin public.bank_origin not null,
  subject_id uuid not null references public.subjects (id),
  topic text check (topic is null or length(btrim(topic)) > 0),       -- 主題／章節，例如「董事會」「營業稅」

  -- 歷屆題（origin = past_exam）才有
  exam_id uuid references public.exams (id) on delete restrict,
  question_no integer check (question_no is null or question_no > 0),
  source_file text,
  source_page integer check (source_page is null or source_page >= 1), -- PDF 實體頁碼（1-based）

  stem text not null check (length(btrim(stem)) > 0),
  table_data jsonb check (
    table_data is null or (
      jsonb_typeof(table_data) = 'object'
      and jsonb_typeof(table_data -> 'head') = 'array'
      and jsonb_typeof(table_data -> 'rows') = 'array')),             -- {head:[...], rows:[[...]]}
  stem_after_table text,                                              -- 表格之後的題幹
  options jsonb not null check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 5),
  answer text not null check (answer ~ '^[A-E]$'),
  answer_source text not null default '自訂'
    check (answer_source in ('考選部公告', '高點詳解', '自訂')),
  correction_note text,                                               -- 更正答案等說明
  explanation text not null default '',
  standards text[] not null default '{}',                             -- 規範依據名稱（準則、IFRS…）
  note text,

  status public.bank_status not null default 'draft',
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- 歷屆題必須有考試、題號與來源頁碼；自訂題不得有（不依年度劃分）
  constraint bank_origin_fields check (
    case origin
      when 'past_exam' then exam_id is not null and question_no is not null
                            and source_file is not null and source_page is not null
      else exam_id is null and question_no is null and source_file is null and source_page is null
    end),
  -- 答案必須落在選項範圍內（A 為第 1 項…）
  constraint bank_answer_in_options check (position(answer in 'ABCDE') <= jsonb_array_length(options)),
  -- 發佈的題目必須有解析；歷屆題必須註明答案來源（自訂題不得標成歷屆來源）
  constraint bank_published_has_explanation check (status = 'draft' or length(btrim(explanation)) > 0),
  constraint bank_answer_source_matches_origin check (
    (origin = 'custom' and answer_source = '自訂') or (origin = 'past_exam' and answer_source <> '自訂'))
);
create unique index bank_questions_exam_no_uq on public.bank_questions (exam_id, question_no) where exam_id is not null;
create index bank_questions_subject_idx on public.bank_questions (subject_id, status);
create index bank_questions_topic_idx on public.bank_questions (subject_id, topic) where topic is not null;
create index bank_questions_created_by_idx on public.bank_questions (created_by);
create trigger bank_questions_set_updated_at before update on public.bank_questions
  for each row execute function public.set_updated_at();

-- 選項必須全是非空字串
create function public.bank_questions_validate() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_opt jsonb;
begin
  for v_opt in select * from jsonb_array_elements(new.options) loop
    if jsonb_typeof(v_opt) <> 'string' or length(btrim(v_opt #>> '{}')) = 0 then
      raise exception 'every option must be a non-empty string' using errcode = '23514';
    end if;
  end loop;
  return new;
end;
$$;
create trigger bank_questions_validate before insert or update of options on public.bank_questions
  for each row execute function public.bank_questions_validate();

-- ---------------------------------------------------------------------------
-- bank_question_laws：題目 ↔ 法條（只存代碼與條號；文字取自 law_articles）
-- ---------------------------------------------------------------------------
create table public.bank_question_laws (
  question_id uuid not null references public.bank_questions (id) on delete cascade,
  law_pcode text not null references public.laws (pcode),
  article_no text not null check (article_no ~ '^[0-9]+(-[0-9]+)*$'),
  position smallint not null default 0,
  primary key (question_id, law_pcode, article_no)
);
create index bank_question_laws_law_idx on public.bank_question_laws (law_pcode, article_no);

-- 新增連結時，該法條必須真的存在於 law_articles
create function public.bank_question_laws_validate() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.law_articles a where a.law_pcode = new.law_pcode and a.article_no = new.article_no
  ) then
    raise exception 'law article % of % does not exist', new.article_no, new.law_pcode using errcode = '23503';
  end if;
  return new;
end;
$$;
create trigger bank_question_laws_validate before insert or update on public.bank_question_laws
  for each row execute function public.bank_question_laws_validate();

-- 目前使用者能不能編輯某題（admin 全部；reviewer 只限自己的自訂草稿）
create function public.bank_question_editable(p_question uuid) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.bank_questions q
    where q.id = p_question
      and (
        public.is_admin()
        or (public.is_staff() and q.origin = 'custom' and q.status = 'draft' and q.created_by = (select auth.uid()))
      )
  );
$$;
revoke all on function public.bank_question_editable(uuid) from public, anon;
grant execute on function public.bank_question_editable(uuid) to authenticated, service_role;

-- 題目 + 現行法條文字（security_invoker：依呼叫者的 RLS 過濾）
create view public.bank_question_law_texts with (security_invoker = true) as
select l.question_id, l.position, lw.pcode, lw.name as law_name, a.article_label,
       a.content, lw.last_modified, lw.source_url, lw.source_name, lw.source_snapshot
from public.bank_question_laws l
join public.laws lw on lw.pcode = l.law_pcode
join lateral (
  select a2.article_label, a2.content from public.law_articles a2
  where a2.law_pcode = l.law_pcode and a2.article_no = l.article_no
  order by a2.seq limit 1
) a on true;

-- ---------------------------------------------------------------------------
-- 權限與 RLS
-- ---------------------------------------------------------------------------
alter table public.subjects enable row level security;
alter table public.bank_questions enable row level security;
alter table public.bank_question_laws enable row level security;

revoke all on public.subjects, public.bank_questions, public.bank_question_laws, public.bank_question_law_texts
  from public, anon;
grant select, insert, update, delete on public.subjects, public.bank_questions, public.bank_question_laws
  to authenticated, service_role;
grant select on public.bank_question_law_texts to authenticated, service_role;
-- import_bank_questions 以 service_role 建立考試科目列（RLS 對 service_role 不適用，但仍需表權限）
grant select, insert on public.exams to service_role;

create policy subjects_select on public.subjects for select to authenticated using (true);
create policy subjects_write_admin on public.subjects for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy bank_questions_select on public.bank_questions for select to authenticated using (
  public.is_staff()
  or (
    status = 'published'
    and (origin = 'custom' or exists (select 1 from public.exams e where e.id = exam_id and e.is_published))
  )
);
create policy bank_questions_insert on public.bank_questions for insert to authenticated with check (
  public.is_admin()
  or (public.is_staff() and origin = 'custom' and status = 'draft' and created_by = (select auth.uid()))
);
create policy bank_questions_update on public.bank_questions for update to authenticated
  using (
    public.is_admin()
    or (public.is_staff() and origin = 'custom' and status = 'draft' and created_by = (select auth.uid()))
  )
  with check (
    public.is_admin()
    or (public.is_staff() and origin = 'custom' and status = 'draft' and created_by = (select auth.uid()))
  );
create policy bank_questions_delete on public.bank_questions for delete to authenticated using (
  public.is_admin()
  or (public.is_staff() and origin = 'custom' and status = 'draft' and created_by = (select auth.uid()))
);

-- 連結：讀取跟隨題目（父表 RLS 會過濾）；寫入必須能編輯該題
create policy bank_question_laws_select on public.bank_question_laws for select to authenticated using (
  exists (select 1 from public.bank_questions q where q.id = question_id)
);
create policy bank_question_laws_write on public.bank_question_laws for all to authenticated
  using (public.bank_question_editable(question_id))
  with check (public.bank_question_editable(question_id));

-- ---------------------------------------------------------------------------
-- import_bank_questions：整批匯入歷屆題（一次交易，只有 service_role）
-- p_items: [{
--   subject, isLaw?, exam:{rocYear, session, examName}, no, stem, stemAfterTable?, table?, options:[..],
--   answer, answerSource, explanation, standards:[..], note?, sourceFile, sourcePage,
--   laws:[{pcode, articleNo}]
-- }]
-- p_publish：true 時題目直接 published（學生仍須等該考試被公開才看得到）
-- 重跑會以 (exam, 題號) 覆蓋同一題，不會重複；任何一題壞掉整批回復。
-- ---------------------------------------------------------------------------
create function public.import_bank_questions(p_items jsonb, p_publish boolean default false) returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_item jsonb;
  v_subject uuid;
  v_exam uuid;
  v_qid uuid;
  v_n integer := 0;
  v_law jsonb;
  v_pos smallint;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'p_items must be a non-empty array' using errcode = '22023';
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    insert into public.subjects (name, is_law)
    values (v_item ->> 'subject', coalesce((v_item ->> 'isLaw')::boolean, false))
    on conflict (name) do nothing;
    select id into v_subject from public.subjects where name = v_item ->> 'subject';

    insert into public.exams (roc_year, session, exam_name, subject_name)
    values ((v_item #>> '{exam,rocYear}')::smallint, coalesce((v_item #>> '{exam,session}')::smallint, 1),
            v_item #>> '{exam,examName}', v_item ->> 'subject')
    on conflict (roc_year, session, exam_name, subject_name) do nothing;
    select id into v_exam from public.exams
    where roc_year = (v_item #>> '{exam,rocYear}')::smallint
      and session = coalesce((v_item #>> '{exam,session}')::smallint, 1)
      and exam_name = v_item #>> '{exam,examName}' and subject_name = v_item ->> 'subject';

    insert into public.bank_questions as q (
      origin, subject_id, topic, exam_id, question_no, source_file, source_page, stem, table_data, stem_after_table,
      options, answer, answer_source, correction_note, explanation, standards, note, status
    ) values (
      'past_exam', v_subject, nullif(v_item ->> 'topic', ''), v_exam, (v_item ->> 'no')::integer,
      v_item ->> 'sourceFile', (v_item ->> 'sourcePage')::integer, v_item ->> 'stem',
      case when jsonb_typeof(v_item -> 'table') = 'object' then v_item -> 'table' end,
      nullif(v_item ->> 'stemAfterTable', ''), v_item -> 'options', v_item ->> 'answer',
      v_item ->> 'answerSource', nullif(v_item ->> 'correctionNote', ''), coalesce(v_item ->> 'explanation', ''),
      coalesce(array(select jsonb_array_elements_text(coalesce(v_item -> 'standards', '[]'::jsonb))), '{}'),
      nullif(v_item ->> 'note', ''), case when p_publish then 'published'::public.bank_status else 'draft' end
    )
    on conflict (exam_id, question_no) where exam_id is not null do update set
      subject_id = excluded.subject_id, topic = excluded.topic, source_file = excluded.source_file,
      source_page = excluded.source_page, stem = excluded.stem, table_data = excluded.table_data,
      stem_after_table = excluded.stem_after_table, options = excluded.options, answer = excluded.answer,
      answer_source = excluded.answer_source, correction_note = excluded.correction_note,
      explanation = excluded.explanation, standards = excluded.standards, note = excluded.note,
      status = excluded.status
    returning q.id into v_qid;

    delete from public.bank_question_laws where question_id = v_qid;
    v_pos := 0;
    for v_law in select * from jsonb_array_elements(coalesce(v_item -> 'laws', '[]'::jsonb)) loop
      insert into public.bank_question_laws (question_id, law_pcode, article_no, position)
      values (v_qid, v_law ->> 'pcode', v_law ->> 'articleNo', v_pos);
      v_pos := v_pos + 1;
    end loop;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke all on function public.import_bank_questions(jsonb, boolean) from public, anon, authenticated;
grant execute on function public.import_bank_questions(jsonb, boolean) to service_role;
