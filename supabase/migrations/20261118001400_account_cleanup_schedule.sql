do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('taspa-account-cleanup','*/5 * * * *',$task$
      select net.http_post(
        url := base.decrypted_secret || '/functions/v1/maintenance',
        headers := jsonb_build_object('Content-Type','application/json','x-taspa-worker',worker.decrypted_secret),
        body := '{"job":"deletions"}'::jsonb, timeout_milliseconds := 60000)
      from vault.decrypted_secrets base,vault.decrypted_secrets worker
      where base.name = 'taspa_project_url' and worker.name = 'taspa_worker_key'
        and exists (select 1 from private.account_deletion_jobs j where j.finished_at is null and j.due_at <= now());
    $task$);
  end if;
end;
$$;
