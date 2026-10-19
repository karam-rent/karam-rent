-- ============================================================
-- نظام إيجارات كرم — إرفاق مستندات العقود (PDF / صور / Word)
-- شغّله مرة واحدة: Supabase ← SQL Editor ← New query ← الصق ← Run
-- آمن للتشغيل أكثر من مرة. الملفات خاصة — لا تُفتح إلا لمستخدمي البرنامج حسب المشروع.
-- ============================================================

-- 1) مخزن الملفات (خاص، حد الملف 20 ميجا)
insert into storage.buckets (id, name, public, file_size_limit)
values ('contracts', 'contracts', false, 20971520)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

-- 2) الصلاحيات: المسار يبدأ باسم المشروع  mall/<رقم العقد>/<الملف>
drop policy if exists karam_docs_read   on storage.objects;
drop policy if exists karam_docs_insert on storage.objects;
drop policy if exists karam_docs_delete on storage.objects;

create policy karam_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'contracts' and public.app_role() is not null
         and public.has_project((storage.foldername(name))[1]));

create policy karam_docs_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'contracts' and public.has_perm('edit_contracts')
              and public.has_project((storage.foldername(name))[1]));

create policy karam_docs_delete on storage.objects for delete to authenticated
  using (bucket_id = 'contracts' and public.has_perm('delete')
         and public.has_project((storage.foldername(name))[1]));

select 'تم تفعيل مرفقات العقود' as result;
