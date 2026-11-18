do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron')
    and exists (select 1 from pg_available_extensions where name = 'pg_net')
    and exists (select 1 from pg_available_extensions where name = 'supabase_vault') then
    create extension if not exists pg_cron;
    create extension if not exists pg_net;
    create extension if not exists supabase_vault;
    perform cron.schedule('taspa-push-outbox', '*/5 * * * *', $task$
      select net.http_post(
        url := base.decrypted_secret || '/functions/v1/maintenance',
        headers := jsonb_build_object('Content-Type','application/json','x-taspa-worker',worker.decrypted_secret),
        body := '{"job":"push"}'::jsonb,
        timeout_milliseconds := 60000
      )
      from vault.decrypted_secrets base, vault.decrypted_secrets worker
      where base.name = 'taspa_project_url' and worker.name = 'taspa_worker_key';
    $task$);
  end if;
end;
$$;
