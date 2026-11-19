-- 網頁內建題存入雲端：新增 builtin_id 欄位（避免重複匯入、讓網頁略過雲端副本）與批次匯入函式。
alter table public.bank_questions add column if not exists builtin_id text;
comment on column public.bank_questions.builtin_id is '網頁內建題的 id（例如 lb2-0001、au-0001）；用來避免重複匯入，也讓網頁略過這些雲端副本，不與內建題重複出現。';
create unique index if not exists bank_questions_builtin_id_key on public.bank_questions (builtin_id) where builtin_id is not null;

create or replace function public.import_builtin_questions(items jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r jsonb;
  l jsonb;
  v_sub uuid;
  v_qid uuid;
  v_pcode text;
  v_pos int;
  v_ins int := 0;
  v_skip int := 0;
begin
  if items is null or jsonb_typeof(items) <> 'array' then
    raise exception 'items must be a JSON array' using errcode = '22023';
  end if;
  for r in select * from jsonb_array_elements(items) loop
    v_qid := null;
    if coalesce(r->>'builtin_id', '') = '' then
      raise exception 'builtin_id is required' using errcode = '22023';
    end if;
    select s.id into v_sub from public.subjects s where s.name = r->>'subject';
    if v_sub is null then
      raise exception 'unknown subject: %', r->>'subject' using errcode = '23503';
    end if;
    insert into public.bank_questions
      (origin, subject_id, topic, stem, options, answer, answer_source, explanation, standards, status, created_by, builtin_id)
    values
      ('custom', v_sub, nullif(btrim(coalesce(r->>'topic', '')), ''), r->>'stem', r->'options', r->>'answer', '自訂',
       coalesce(r->>'explanation', ''),
       coalesce(array(select jsonb_array_elements_text(coalesce(r->'standards', '[]'::jsonb))), '{}'::text[]),
       'draft', (select auth.uid()), r->>'builtin_id')
    on conflict (builtin_id) where builtin_id is not null do nothing
    returning id into v_qid;
    if v_qid is null then
      v_skip := v_skip + 1;
      continue;
    end if;
    v_ins := v_ins + 1;
    v_pos := 0;
    for l in select * from jsonb_array_elements(coalesce(r->'laws', '[]'::jsonb)) loop
      select x.pcode into v_pcode from public.laws x where x.name = l->>'lawName';
      if v_pcode is null then
        raise exception 'unknown law: %', l->>'lawName' using errcode = '23503';
      end if;
      insert into public.bank_question_laws (question_id, law_pcode, article_no, position)
      values (v_qid, v_pcode, l->>'articleNo', v_pos)
      on conflict do nothing;
      v_pos := v_pos + 1;
    end loop;
  end loop;
  return jsonb_build_object('inserted', v_ins, 'skipped', v_skip);
end;
$$;

revoke all on function public.import_builtin_questions(jsonb) from public, anon;
grant execute on function public.import_builtin_questions(jsonb) to authenticated;
