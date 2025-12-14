alter table "public"."companies" enable row level security;

drop trigger if exists "CV Upload Hook" on "storage"."buckets";


