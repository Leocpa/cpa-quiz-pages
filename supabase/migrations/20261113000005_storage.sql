-- CPA-SmartBank 第一階段：來源 PDF 的私有 Storage bucket 與政策
-- 僅在 Supabase（存在 storage schema）時套用；一般 PostgreSQL 會略過。

do $$
begin
  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then
    raise notice 'storage schema not found, skipping bucket setup';
    return;
  end if;

  insert into storage.buckets (id, name, public)
  values ('exam-pdfs', 'exam-pdfs', false)
  on conflict (id) do update set public = false;

  execute $p$
    create policy exam_pdfs_staff_read on storage.objects for select to authenticated
      using (bucket_id = 'exam-pdfs' and public.is_staff())
  $p$;
  execute $p$
    create policy exam_pdfs_staff_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'exam-pdfs' and public.is_staff())
  $p$;
  execute $p$
    create policy exam_pdfs_admin_delete on storage.objects for delete to authenticated
      using (bucket_id = 'exam-pdfs' and public.is_admin())
  $p$;
end
$$;
