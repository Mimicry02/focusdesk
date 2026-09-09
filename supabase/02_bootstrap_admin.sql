-- 1. Create YOUR account via Supabase Dashboard > Authentication > Users > Add user.
-- 2. Replace the email below with the exact email of that account.
-- 3. Run once as project owner. No hardcoded password and no first-signup-admin behavior.
begin;
do $$
declare owner_email text := 'GANTI_DENGAN_EMAIL_ANDA@gmail.com'; owner_id uuid;
begin
 select id into owner_id from auth.users where lower(email)=lower(owner_email);
 if owner_id is null then raise exception 'Create the Auth user first and replace owner_email with your exact email.'; end if;
 if exists(select 1 from public.fd_profiles where role='admin' and is_active and id<>owner_id) then
  raise exception 'An admin already exists. Use User management to grant additional access.';
 end if;
 update public.fd_profiles set role='admin',is_active=true,display_name=coalesce(nullif(display_name,''),'Justin'),updated_at=now() where id=owner_id;
 if not found then raise exception 'Run 01_schema.sql first'; end if;
end $$;
commit;
