-- CPA-SmartBank 第一階段：核心資料表
-- 已發佈題庫 (questions / question_answers) 與其來源 PDF (source_documents) 的關聯。
-- 頁碼一律為 PDF 實體頁碼（1-based），與 PDF 內印刷頁碼無關。

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.app_role as enum ('admin', 'reviewer', 'student');
create type public.document_kind as enum ('questions', 'answers', 'corrections');
create type public.import_status as enum ('uploaded', 'parsed', 'published', 'rejected', 'failed');
create type public.answer_kind as enum ('standard', 'corrected');
-- none: 無更正；changed: 更正為單一答案；all_credit: 一律給分；multi_accept: 多個答案皆給分
create type public.correction_kind as enum ('none', 'changed', 'all_credit', 'multi_accept');
create type public.anomaly_severity as enum ('error', 'warning', 'info');
create type public.anomaly_status as enum ('open', 'resolved', 'dismissed');

-- ---------------------------------------------------------------------------
-- 共用 trigger
-- ---------------------------------------------------------------------------
create function public.set_updated_at() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- 答案陣列與 correction_kind 的一致性檢查（staging 與 published 共用）
create function public.answers_match_kind(p_kind public.correction_kind, p_answers text[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case p_kind
    when 'none'         then cardinality(p_answers) = 1
    when 'changed'      then cardinality(p_answers) = 1
    when 'multi_accept' then cardinality(p_answers) >= 2
    when 'all_credit'   then cardinality(p_answers) = 0
  end
  and p_answers <@ array['A','B','C','D','E']::text[];
$$;

-- ---------------------------------------------------------------------------
-- profiles：角色存放於此（不可信任 user_metadata）
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  role public.app_role not null default 'student',
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger profiles_set_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

-- 新使用者自動建立 profile（一律 student；提權只能由 admin 於 profiles 修改）
create function public.handle_new_user() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, role) values (new.id, 'student')
  on conflict (id) do nothing;
  return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 套用 migration 之前就已存在的使用者：補建 profile（一律 student，需由 admin 另行提權）
insert into public.profiles (id, role)
select id, 'student' from auth.users
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- exams：一份考試科目（例如 民國 114 年第 1 次 會計師 審計學）
-- ---------------------------------------------------------------------------
create table public.exams (
  id uuid primary key default gen_random_uuid(),
  roc_year smallint not null check (roc_year between 1 and 300),
  session smallint not null default 1 check (session >= 1),
  exam_name text not null check (length(btrim(exam_name)) > 0),
  subject_name text not null check (length(btrim(subject_name)) > 0),
  subject_code text,
  is_published boolean not null default false,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (roc_year, session, exam_name, subject_name)
);
create trigger exams_set_updated_at before update on public.exams
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- import_batches / source_documents
-- ---------------------------------------------------------------------------
create table public.import_batches (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams (id),
  status public.import_status not null default 'uploaded',
  parser_version text,
  summary jsonb not null default '{}'::jsonb,
  failure_reason text,
  created_by uuid references auth.users (id),
  published_by uuid references auth.users (id),
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((status = 'published') = (published_at is not null))
);
create index import_batches_exam_idx on public.import_batches (exam_id);
create trigger import_batches_set_updated_at before update on public.import_batches
  for each row execute function public.set_updated_at();

create table public.source_documents (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.import_batches (id) on delete cascade,
  exam_id uuid not null references public.exams (id),
  kind public.document_kind not null,
  file_name text not null,
  storage_path text not null,
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  page_count integer not null check (page_count > 0),
  byte_size bigint check (byte_size is null or byte_size >= 0),
  uploaded_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  unique (batch_id, kind)
);
create index source_documents_sha_idx on public.source_documents (sha256);
create index source_documents_exam_idx on public.source_documents (exam_id);

-- 頁碼必須落在該 PDF 的頁數範圍內，且文件屬於同一批次（staging）或同一考試（published）
create function public.assert_page_in_document(p_doc uuid, p_page integer, p_page_end integer default null)
returns void
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer;
begin
  select page_count into v_count from public.source_documents where id = p_doc;
  if v_count is null then
    raise exception 'source document % does not exist', p_doc using errcode = '23503';
  end if;
  if p_page < 1 or p_page > v_count then
    raise exception 'source page % is outside document % (1..%)', p_page, p_doc, v_count
      using errcode = '23514';
  end if;
  if p_page_end is not null and (p_page_end < p_page or p_page_end > v_count) then
    raise exception 'source page range %-% is invalid for document % (1..%)', p_page, p_page_end, p_doc, v_count
      using errcode = '23514';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 已發佈題庫
-- ---------------------------------------------------------------------------
create table public.questions (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams (id) on delete cascade,
  question_no integer not null check (question_no > 0),
  stem text not null,
  options jsonb not null check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 5),
  batch_id uuid not null references public.import_batches (id),
  source_document_id uuid not null references public.source_documents (id),
  source_page integer not null check (source_page >= 1),
  source_page_end integer check (source_page_end is null or source_page_end >= source_page),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (exam_id, question_no)
);
create index questions_batch_idx on public.questions (batch_id);
create index questions_source_document_idx on public.questions (source_document_id);
create trigger questions_set_updated_at before update on public.questions
  for each row execute function public.set_updated_at();

create function public.questions_validate_source() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform public.assert_page_in_document(new.source_document_id, new.source_page, new.source_page_end);
  if not exists (
    select 1 from public.source_documents d
    where d.id = new.source_document_id and d.exam_id = new.exam_id and d.kind = 'questions'
  ) then
    raise exception 'question source document must be a questions PDF of the same exam'
      using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger questions_validate_source before insert or update of source_document_id, source_page, source_page_end, exam_id
  on public.questions for each row execute function public.questions_validate_source();

-- 標準答案 + 更正答案配對。effective_answers 為實際給分答案：
--   none → {標準答案}；changed → {更正答案}；multi_accept → 多個答案；all_credit → {'*'}（任何作答皆給分）
create table public.question_answers (
  question_id uuid primary key references public.questions (id) on delete cascade,
  standard_answer text not null check (standard_answer ~ '^[A-E]$'),
  standard_source_document_id uuid not null references public.source_documents (id),
  standard_source_page integer not null check (standard_source_page >= 1),
  correction_kind public.correction_kind not null default 'none',
  corrected_answers text[] not null default '{}',
  corrected_source_document_id uuid references public.source_documents (id),
  corrected_source_page integer check (corrected_source_page is null or corrected_source_page >= 1),
  correction_note text,
  effective_answers text[] not null,
  updated_at timestamptz not null default now(),
  check (
    case correction_kind
      when 'none' then
        cardinality(corrected_answers) = 0
        and corrected_source_document_id is null
        and corrected_source_page is null
      else
        corrected_source_document_id is not null
        and corrected_source_page is not null
        and public.answers_match_kind(correction_kind, corrected_answers)
    end
  )
);
create index question_answers_std_doc_idx on public.question_answers (standard_source_document_id);
create index question_answers_cor_doc_idx on public.question_answers (corrected_source_document_id)
  where corrected_source_document_id is not null;
create trigger question_answers_set_updated_at before update on public.question_answers
  for each row execute function public.set_updated_at();

create function public.question_answers_prepare() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_exam uuid;
begin
  select exam_id into v_exam from public.questions where id = new.question_id;

  perform public.assert_page_in_document(new.standard_source_document_id, new.standard_source_page);
  if not exists (
    select 1 from public.source_documents d
    where d.id = new.standard_source_document_id and d.exam_id = v_exam and d.kind = 'answers'
  ) then
    raise exception 'standard answer source must be an answers PDF of the same exam' using errcode = '23514';
  end if;

  if new.correction_kind <> 'none' then
    perform public.assert_page_in_document(new.corrected_source_document_id, new.corrected_source_page);
    if not exists (
      select 1 from public.source_documents d
      where d.id = new.corrected_source_document_id and d.exam_id = v_exam and d.kind = 'corrections'
    ) then
      raise exception 'corrected answer source must be a corrections PDF of the same exam' using errcode = '23514';
    end if;
  end if;

  new.effective_answers := case new.correction_kind
    when 'none' then array[new.standard_answer]
    when 'all_credit' then array['*']
    else new.corrected_answers
  end;
  return new;
end;
$$;
create trigger question_answers_prepare before insert or update on public.question_answers
  for each row execute function public.question_answers_prepare();
