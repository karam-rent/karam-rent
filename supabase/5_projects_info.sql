-- تحديث بيانات شركتي كرم فيلج وكرم العقارية (لمن شغّل 4_projects.sql قبل إضافة البيانات)
update public.projects set data = data || '{"company":"شركة مجمع كرم مول التجاري","cr":"1122005677","vat":"310154341300003","addr":"المجمعة - حي المستقبل - طريق الملك خالد"}'::jsonb where id = 'village';
update public.projects set data = data || '{"company":"شركة كرم العربية العقارية","cr":"1122005091","vat":"310719783200003","logo":"logo-realestate.png"}'::jsonb where id = 'realestate';
select id, data->>'name' as name, data->>'company' as company, data->>'cr' as cr from public.projects order by sort;
