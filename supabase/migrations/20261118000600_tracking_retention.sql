create function private.prune_tracking_receipts() returns void
language sql set search_path = '' as $$
  update private.tracking_operations set receipt = null
  where (user_id, operation_id) in (
    select user_id, operation_id from private.tracking_operations
    where receipt is not null and created_at < now() - interval '24 hours'
    order by created_at limit 1000
  );
  delete from private.tracking_operations
  where (user_id, operation_id) in (
    select user_id, operation_id from private.tracking_operations
    where created_at < now() - interval '35 days'
    order by created_at limit 1000
  );
$$;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('taspa-prune-tracking-receipts', '17 * * * *',
      'select private.prune_tracking_receipts()');
  end if;
end;
$$;
