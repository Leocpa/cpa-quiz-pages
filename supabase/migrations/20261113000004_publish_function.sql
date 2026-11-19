-- CPA-SmartBank 第一階段：發佈批次（暫存 → 正式題庫），單一交易、DB 端強制完整性檢查
-- 不依賴應用層是否已跑完異常偵測：即使前端被繞過，這裡仍會擋下不完整的批次。

create function public.publish_import_batch(p_batch_id uuid, p_replace boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch public.import_batches%rowtype;
  v_open_errors integer;
  v_no_questions integer;
  v_missing integer[];
  v_orphan integer[];
  v_questions integer;
  v_corrections integer;
begin
  if not public.is_admin() then
    raise exception 'only admin can publish an import batch' using errcode = '42501';
  end if;

  select * into v_batch from public.import_batches where id = p_batch_id for update;
  if not found then
    raise exception 'import batch % not found', p_batch_id using errcode = 'P0002';
  end if;
  if v_batch.status <> 'parsed' then
    raise exception 'import batch % has status %, only parsed batches can be published', p_batch_id, v_batch.status
      using errcode = '55000';
  end if;

  select count(*) into v_open_errors
    from public.import_anomalies
   where batch_id = p_batch_id and severity = 'error' and status = 'open';
  if v_open_errors > 0 then
    raise exception 'batch has % unresolved error anomalies', v_open_errors using errcode = '55000';
  end if;

  select count(*) into v_no_questions
    from public.staged_questions where batch_id = p_batch_id and not is_excluded;
  if v_no_questions = 0 then
    raise exception 'batch has no active staged questions' using errcode = '55000';
  end if;

  -- 每一題都必須有未排除的標準答案
  select array_agg(q.question_no order by q.question_no) into v_missing
    from public.staged_questions q
   where q.batch_id = p_batch_id and not q.is_excluded
     and not exists (
       select 1 from public.staged_answers a
        where a.batch_id = q.batch_id and a.question_no = q.question_no
          and a.answer_kind = 'standard' and not a.is_excluded
     );
  if v_missing is not null then
    raise exception 'questions without a standard answer: %', v_missing using errcode = '55000';
  end if;

  -- 標準答案 / 更正答案不得指向不存在（或已排除）的題目
  select array_agg(distinct a.question_no order by a.question_no) into v_orphan
    from public.staged_answers a
   where a.batch_id = p_batch_id and not a.is_excluded
     and not exists (
       select 1 from public.staged_questions q
        where q.batch_id = a.batch_id and q.question_no = a.question_no and not q.is_excluded
     );
  if v_orphan is not null then
    raise exception 'answers reference unknown questions: %', v_orphan using errcode = '55000';
  end if;

  if exists (select 1 from public.questions where exam_id = v_batch.exam_id) then
    if not p_replace then
      raise exception 'exam already has published questions; pass p_replace => true to replace them'
        using errcode = '55000';
    end if;
    delete from public.questions where exam_id = v_batch.exam_id;  -- question_answers 隨之 cascade
  end if;

  insert into public.questions
    (exam_id, question_no, stem, options, batch_id, source_document_id, source_page, source_page_end)
  select v_batch.exam_id, q.question_no, q.stem, q.options, q.batch_id,
         q.source_document_id, q.source_page, q.source_page_end
    from public.staged_questions q
   where q.batch_id = p_batch_id and not q.is_excluded
   order by q.question_no;
  get diagnostics v_questions = row_count;

  insert into public.question_answers
    (question_id, standard_answer, standard_source_document_id, standard_source_page,
     correction_kind, corrected_answers, corrected_source_document_id, corrected_source_page, correction_note)
  select pq.id,
         sa.answers[1], sa.source_document_id, sa.source_page,
         coalesce(ca.correction_kind, 'none'),
         coalesce(ca.answers, '{}'),
         ca.source_document_id, ca.source_page, ca.note
    from public.questions pq
    join public.staged_answers sa
      on sa.batch_id = pq.batch_id and sa.question_no = pq.question_no
     and sa.answer_kind = 'standard' and not sa.is_excluded
    left join public.staged_answers ca
      on ca.batch_id = pq.batch_id and ca.question_no = pq.question_no
     and ca.answer_kind = 'corrected' and not ca.is_excluded
   where pq.batch_id = p_batch_id;

  select count(*) into v_corrections
    from public.staged_answers
   where batch_id = p_batch_id and answer_kind = 'corrected' and not is_excluded;

  update public.import_batches
     set status = 'published',
         published_at = now(),
         published_by = (select auth.uid()),
         summary = summary || jsonb_build_object('published_questions', v_questions,
                                                 'published_corrections', v_corrections)
   where id = p_batch_id;

  return jsonb_build_object('batch_id', p_batch_id, 'questions', v_questions, 'corrections', v_corrections);
end;
$$;

revoke all on function public.publish_import_batch(uuid, boolean) from public, anon;
grant execute on function public.publish_import_batch(uuid, boolean) to authenticated;
