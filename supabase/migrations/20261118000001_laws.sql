-- CPA-SmartBank：法規資料（全國法規資料庫）
--
-- 資料來源：法務部「全國法規資料庫」公開資料（政府資料開放授權條款－第 1 版）。
-- 使用時須標示資料來源為「全國法規資料庫」(https://law.moj.gov.tw/)；
-- 資料由 scripts/import-laws.ts 經 public.import_law() 整批寫入，
-- 每部法規一次交易，不會留下「只寫了一半」的條文。
--
-- 讀取：任何已登入使用者（法規是公開資訊，與題庫是否公開無關）。
-- 寫入：只有 service_role（匯入腳本）可呼叫 import_law；admin 透過 RLS 也可直接改，其他角色不行。

create table public.laws (
  pcode           text primary key check (pcode ~ '^[A-Z][0-9]{7}$'),
  name            text not null check (length(btrim(name)) > 0),
  nature          text,                 -- 法規性質：法律 / 命令 ...
  category        text,                 -- 法規類別（主管機關＞類目）
  source_url      text,
  last_modified   date,                 -- 最新異動日期
  effective_date  date,                 -- 生效日期
  effective_note  text,                 -- 生效內容（例如「自公布後六個月施行」）
  english_name    text,
  history         text,                 -- 沿革內容
  source_name     text not null default '全國法規資料庫',
  source_snapshot date not null,        -- 來源資料集的更新日（UpdateDate）
  imported_at     timestamptz not null default now()
);

create table public.law_articles (
  id            bigint generated always as identity primary key,
  law_pcode     text not null references public.laws(pcode) on delete cascade,
  seq           integer not null check (seq > 0),   -- 在該法規中的出現順序（含增訂條文，如 28-1）
  article_no    text not null check (article_no ~ '^[0-9]+(-[0-9]+)*$'),  -- '3'、'28-1'
  article_label text not null,                     -- 原文條號，如「第 28-1 條」
  chapter       text,                              -- 該條所屬的編章節標題
  content       text not null,
  unique (law_pcode, seq)
);
create index law_articles_law_no_idx on public.law_articles (law_pcode, article_no);

alter table public.laws enable row level security;
alter table public.law_articles enable row level security;

revoke all on public.laws, public.law_articles from public, anon;
grant select, insert, update, delete on public.laws, public.law_articles to authenticated, service_role;

create policy laws_select on public.laws for select to authenticated using (true);
create policy laws_write_admin on public.laws for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy law_articles_select on public.law_articles for select to authenticated using (true);
create policy law_articles_write_admin on public.law_articles for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------------------
-- 匯入：一次交易取代一部法規的所有條文
-- p_law      {pcode,name,nature,category,sourceUrl,lastModified,effectiveDate,effectiveNote,englishName,history,snapshot}
-- p_articles [{seq,articleNo,articleLabel,chapter,content}, ...]（不得為空）
-- ---------------------------------------------------------------------------
create function public.import_law(p_law jsonb, p_articles jsonb) returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_pcode text := p_law ->> 'pcode';
  v_n     integer;
begin
  if jsonb_typeof(p_articles) is distinct from 'array' or jsonb_array_length(p_articles) = 0 then
    raise exception 'import_law: p_articles must be a non-empty array' using errcode = '22023';
  end if;

  insert into public.laws (pcode, name, nature, category, source_url, last_modified, effective_date,
                           effective_note, english_name, history, source_snapshot, imported_at)
  values (v_pcode, p_law ->> 'name', nullif(p_law ->> 'nature', ''), nullif(p_law ->> 'category', ''),
          nullif(p_law ->> 'sourceUrl', ''), nullif(p_law ->> 'lastModified', '')::date,
          nullif(p_law ->> 'effectiveDate', '')::date, nullif(p_law ->> 'effectiveNote', ''),
          nullif(p_law ->> 'englishName', ''), nullif(p_law ->> 'history', ''),
          (p_law ->> 'snapshot')::date, now())
  on conflict (pcode) do update set
    name = excluded.name, nature = excluded.nature, category = excluded.category,
    source_url = excluded.source_url, last_modified = excluded.last_modified,
    effective_date = excluded.effective_date, effective_note = excluded.effective_note,
    english_name = excluded.english_name, history = excluded.history,
    source_snapshot = excluded.source_snapshot, imported_at = now();

  delete from public.law_articles where law_pcode = v_pcode;

  insert into public.law_articles (law_pcode, seq, article_no, article_label, chapter, content)
  select v_pcode, (a ->> 'seq')::integer, a ->> 'articleNo', a ->> 'articleLabel',
         nullif(a ->> 'chapter', ''), a ->> 'content'
  from jsonb_array_elements(p_articles) a;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke all on function public.import_law(jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.import_law(jsonb, jsonb) to service_role;
