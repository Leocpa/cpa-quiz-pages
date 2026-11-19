-- CPA-SmartBank 第一階段：匯入暫存區（預覽 / 異常審核）
-- 解析結果先進 staged_*，經異常審核後才由 publish_import_batch() 寫入正式題庫。

create table public.staged_questions (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.import_batches (id) on delete cascade,
  question_no integer not null check (question_no > 0),
  stem text not null,
  options jsonb not null check (jsonb_typeof(options) = 'array'),
  source_document_id uuid not null references public.source_documents (id),
  source_page integer not null check (source_page >= 1),
  source_page_end integer check (source_page_end is null or source_page_end >= source_page),
  confidence numeric(3, 2) check (confidence is null or confidence between 0 and 1),
  raw_text text,
  -- 重複題號時，多餘的候選保留但標記為排除；同批次同題號只允許一筆未排除
  is_excluded boolean not null default false,
  edited_by uuid references auth.users (id),
  edited_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index staged_questions_active_no_uq
  on public.staged_questions (batch_id, question_no) where not is_excluded;
create index staged_questions_batch_idx on public.staged_questions (batch_id, question_no);
create index staged_questions_doc_idx on public.staged_questions (source_document_id);

create table public.staged_answers (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.import_batches (id) on delete cascade,
  question_no integer not null check (question_no > 0),
  answer_kind public.answer_kind not null,
  correction_kind public.correction_kind not null default 'none',
  answers text[] not null default '{}',
  raw_text text,
  note text,
  source_document_id uuid not null references public.source_documents (id),
  source_page integer not null check (source_page >= 1),
  is_excluded boolean not null default false,
  edited_by uuid references auth.users (id),
  edited_at timestamptz,
  created_at timestamptz not null default now(),
  check (
    (answer_kind = 'standard' and correction_kind = 'none')
    or (answer_kind = 'corrected' and correction_kind <> 'none')
  ),
  check (public.answers_match_kind(correction_kind, answers))
);
create unique index staged_answers_active_uq
  on public.staged_answers (batch_id, question_no, answer_kind) where not is_excluded;
create index staged_answers_batch_idx on public.staged_answers (batch_id, question_no);
create index staged_answers_doc_idx on public.staged_answers (source_document_id);

create table public.import_anomalies (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.import_batches (id) on delete cascade,
  code text not null,
  severity public.anomaly_severity not null,
  question_no integer,
  message text not null,
  details jsonb not null default '{}'::jsonb,
  source_document_id uuid references public.source_documents (id),
  source_page integer check (source_page is null or source_page >= 1),
  -- 同一異常重新偵測時以 fingerprint 對應，已被審核者處理的不會重複出現
  fingerprint text not null,
  status public.anomaly_status not null default 'open',
  resolution_note text,
  resolved_by uuid references auth.users (id),
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (batch_id, fingerprint),
  check ((status = 'open') = (resolved_at is null))
);
create index import_anomalies_batch_idx on public.import_anomalies (batch_id, status, severity);
create trigger import_anomalies_set_updated_at before update on public.import_anomalies
  for each row execute function public.set_updated_at();

-- staging 的來源頁碼同樣必須落在 PDF 頁數內，且文件屬於同一批次
create function public.staged_validate_source() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_kind public.document_kind;
  v_expected public.document_kind;
begin
  if tg_table_name = 'staged_questions' then
    perform public.assert_page_in_document(new.source_document_id, new.source_page, new.source_page_end);
    v_expected := 'questions';
  else
    perform public.assert_page_in_document(new.source_document_id, new.source_page);
    v_expected := case new.answer_kind when 'standard' then 'answers' else 'corrections' end;
  end if;

  select kind into v_kind from public.source_documents
   where id = new.source_document_id and batch_id = new.batch_id;
  if v_kind is distinct from v_expected then
    raise exception 'staged row requires a % document of the same batch', v_expected using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger staged_questions_validate_source
  before insert or update of source_document_id, source_page, source_page_end, batch_id
  on public.staged_questions for each row execute function public.staged_validate_source();
create trigger staged_answers_validate_source
  before insert or update of source_document_id, source_page, batch_id, answer_kind
  on public.staged_answers for each row execute function public.staged_validate_source();
