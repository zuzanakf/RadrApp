


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "citext" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA "public";






CREATE OR REPLACE FUNCTION "public"."close_pending_matches_when_full"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  -- Only when we transition into 'full'
  if new.status = 'full' and (old.status is distinct from 'full') then
    update radr_user_scores
    set status = 'closed',
        updated_at = now()
    where radr_id = new.id
      and status = 'pending';
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."close_pending_matches_when_full"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."close_scores_when_radr_closed"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  -- Only when status actually changed to 'closed'
  if new.status = 'closed'
     and (old.status is distinct from 'closed') then

    update radr_user_scores
    set status = 'closed'
    where radr_id = new.id
      and status is distinct from 'closed';

  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."close_scores_when_radr_closed"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_build_radr_embeddings"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  -- Fire on brand-new radr, or when relevant fields change
  if (tg_op = 'INSERT')
     or (new.intentions is distinct from old.intentions)
     or (new.bio         is distinct from old.bio)
  then
    -- Avoid flooding: only enqueue if no queued/running job exists for this radr
    if not exists (
      select 1 from public.jobs j
      where j.type = 'build_radr_embeddings'
        and j.status in ('queued','running')
        and (j.payload_json->>'radr_id') = new.id::text
    ) then
      insert into public.jobs (type, payload_json, status)
      values (
        'build_radr_embeddings',
        jsonb_build_object('radr_id', new.id),
        'queued'
      );
    end if;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."enqueue_build_radr_embeddings"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enqueue_compute_embeddings_on_profile_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user_id uuid := new.user_id;
begin
  if (tg_op = 'INSERT')
     or (new.current_role_title        is distinct from old.current_role_title)
     or (new.past_experience           is distinct from old.past_experience)
     or (new.future_career_aspirations is distinct from old.future_career_aspirations)
     or (new.professional_values       is distinct from old.professional_values)
     or (new.professional_interests    is distinct from old.professional_interests)
     or (new.personal_interests        is distinct from old.personal_interests)
     or (new.extracurriculars          is distinct from old.extracurriculars)
  then
    insert into public.jobs(type, payload_json, status)
    values (
      'compute_embeddings',
      jsonb_build_object('user_id', v_user_id),
      'queued'
    )
    on conflict ((payload_json->>'user_id'))
      where type = 'compute_embeddings' and status in ('queued','running')
    do nothing;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."enqueue_compute_embeddings_on_profile_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ensure_single_present_checkin_per_user"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  -- Only do anything when the new row is marked present = true
  if new.present = true then
    -- Set all *other* checkins for this user to present = false
    update public.place_checkins
    set present = false
    where user_id = new.user_id
      and id <> new.id         -- don't touch the current row
      and present = true;      -- only flip ones that are currently true
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."ensure_single_present_checkin_per_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_open_radr_joiners"("p_creator_user_id" "uuid") RETURNS TABLE("radr_id" "uuid", "creator_user_id" "uuid", "joiner_user_id" "uuid", "professional_score" real, "personal_score" real, "overall_score" real, "total_score" real, "three_things" "text"[], "explanation" "jsonb", "common_tags" "text"[], "match_status" "text", "profile_photo_url" "text", "first_name" "text", "last_name" "text", "current_role_title" "text", "company" "text", "profile_bio" "text", "professional_interests" "text"[], "personal_interests" "text"[], "tags" "text"[])
    LANGUAGE "sql" STABLE
    AS $$
  select
    r.id as radr_id,
    r.creator_user_id,
    rus.user_id as joiner_user_id,

    rus.professional_score,
    rus.personal_score,
    rus.overall_score,
    rus.total_score,
    rus.three_things,
    rus.explanation,
    rus.common_tags,
    rus.status as match_status,

    p.profile_photo_url,
    p.first_name,
    p.last_name,
    p.current_role_title,
    p.company,
    p.bio as profile_bio,
    p.professional_interests,
    p.personal_interests,
    p.tags
  from public.radrs r
  join public.radr_user_scores rus
    on rus.radr_id = r.id
   and rus.status = 'active'          -- only users who’ve “joined” the radr
  join public.profiles p
    on p.user_id = rus.user_id
  where
    r.creator_user_id = p_creator_user_id
    and r.status = 'open';            -- only open radr(s) for this creator
$$;


ALTER FUNCTION "public"."get_open_radr_joiners"("p_creator_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_place_checkin_count"("_place_id" "uuid") RETURNS integer
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT count(*)::integer
  FROM place_checkins
  WHERE place_id = _place_id
    AND present = TRUE;
$$;


ALTER FUNCTION "public"."get_place_checkin_count"("_place_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_places_for_dropdown"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'label', p.name,
        'value', p.id
      )
      order by p.name
    ),
    '[]'::jsonb
  )
  from public.places p;
$$;


ALTER FUNCTION "public"."get_places_for_dropdown"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_radr_details"("p_radr_id" "uuid") RETURNS TABLE("radr_id" "uuid", "instructions" "text", "bio" "text")
    LANGUAGE "sql" STABLE
    AS $$
  select
    id          as radr_id,
    instructions,
    bio
  from public.radrs
  where id = p_radr_id;
$$;


ALTER FUNCTION "public"."get_radr_details"("p_radr_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_radr_details_for_joiner"("p_radr_id" "uuid", "p_user_id" "uuid") RETURNS TABLE("radr_id" "uuid", "user_id" "uuid", "creator" boolean, "professional_score" numeric, "personal_score" numeric, "overall_score" numeric, "total_score" numeric, "three_things" "text"[], "explanation" "jsonb", "common_tags" "text"[], "match_status" "text", "profile_photo_url" "text", "first_name" "text", "last_name" "text", "current_role_title" "text", "company" "text", "profile_bio" "text", "professional_interests" "text"[], "personal_interests" "text"[], "tags" "text"[])
    LANGUAGE "sql" STABLE
    AS $$

  select *
  from (

    ----------------------------------------------------------------------
    -- 1) CREATOR ROW — show creator’s match info FOR THIS JOINER
    ----------------------------------------------------------------------
    select
      r.id                              as radr_id,
      r.creator_user_id                 as user_id,
      true                              as creator,

      rus.professional_score,
      rus.personal_score,
      rus.overall_score,
      rus.total_score,
      rus.three_things,
      rus.explanation,
      rus.common_tags,
      rus.status                        as match_status,

      cp.profile_photo_url,
      cp.first_name,
      cp.last_name,
      cp.current_role_title,
      cp.company,
      cp.bio                            as profile_bio,
      cp.professional_interests,
      cp.personal_interests,
      cp.tags

    from public.radrs r
    join public.profiles cp
      on cp.user_id = r.creator_user_id
    left join public.radr_user_scores rus
      on rus.radr_id = r.id
     and rus.user_id = p_user_id               -- ← match row for THIS joiner
     and rus.status = 'active'
    where
      r.id = p_radr_id
      and r.status in ('open','full')


    union all

    ----------------------------------------------------------------------
    -- 2) OTHER JOINERS — exclude the requesting joiner
    ----------------------------------------------------------------------
    select
      r.id                              as radr_id,
      rus.user_id                       as user_id,
      false                             as creator,

      rus.professional_score,
      rus.personal_score,
      rus.overall_score,
      rus.total_score,
      rus.three_things,
      rus.explanation,
      rus.common_tags,
      rus.status                        as match_status,

      p.profile_photo_url,
      p.first_name,
      p.last_name,
      p.current_role_title,
      p.company,
      p.bio                              as profile_bio,
      p.professional_interests,
      p.personal_interests,
      p.tags

    from public.radrs r
    join public.radr_user_scores rus
      on rus.radr_id = r.id
     and rus.status = 'active'
     and rus.user_id <> p_user_id           -- ← don’t show joiner's own match data
    join public.profiles p
      on p.user_id = rus.user_id
    where
      r.id = p_radr_id
      and r.status in ('open','full')

  ) t

  order by creator desc;  -- creator first

$$;


ALTER FUNCTION "public"."get_radr_details_for_joiner"("p_radr_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_radr_profiles_with_flag"("p_radr_id" "uuid") RETURNS TABLE("radr_id" "uuid", "user_id" "uuid", "creator" boolean, "professional_score" numeric, "personal_score" numeric, "overall_score" numeric, "total_score" numeric, "three_things" "text"[], "explanation" "jsonb", "common_tags" "text"[], "match_status" "text", "profile_photo_url" "text", "first_name" "text", "last_name" "text", "current_role_title" "text", "company" "text", "profile_bio" "text", "professional_interests" "text"[], "personal_interests" "text"[], "tags" "text"[])
    LANGUAGE "sql" STABLE
    AS $$select *
  from (
    -- 1) Creator row
    select
      r.id                  as radr_id,
      r.creator_user_id     as user_id,
      true                  as creator,          -- creator flag

      -- creator has no scores for this radr
      null::numeric         as professional_score,
      null::numeric         as personal_score,
      null::numeric         as overall_score,
      null::numeric         as total_score,
      null::text[]          as three_things,     -- match text[]
      null::jsonb           as explanation,      -- 🔁 match jsonb
      null::text[]          as common_tags,      -- match text[]
      null::text            as match_status,

      -- creator profile fields
      cp.profile_photo_url,
      cp.first_name,
      cp.last_name,
      cp.current_role_title,
      cp.company,
      cp.bio                 as profile_bio,
      cp.professional_interests,
      cp.personal_interests,
      cp.tags

    from public.radrs r
    join public.profiles cp
      on cp.user_id = r.creator_user_id
    where
      r.id = p_radr_id
      and r.status in ('open','full')

    union all

    -- 2) Joiner rows
    select
      r.id                  as radr_id,
      rus.user_id           as user_id,
      false                 as creator,          -- joiner

      rus.professional_score,
      rus.personal_score,
      rus.overall_score,
      rus.total_score,
      rus.three_things,                          -- text[]
      rus.explanation,                           -- jsonb
      rus.common_tags,                           -- text[]
      rus.status            as match_status,

      -- joiner profile fields
      p.profile_photo_url,
      p.first_name,
      p.last_name,
      p.current_role_title,
      p.company,
      p.bio                 as profile_bio,
      p.professional_interests,
      p.personal_interests,
      p.tags

    from public.radrs r
    join public.radr_user_scores rus
      on rus.radr_id = r.id
     and rus.status = 'active'
    join public.profiles p
      on p.user_id = rus.user_id
    where
      r.id = p_radr_id
      and r.status in ('open','full')
  ) t
  order by creator desc;  -- creator first, then joiners$$;


ALTER FUNCTION "public"."get_radr_profiles_with_flag"("p_radr_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_radr_with_creator_and_joiners"("p_radr_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$
with radr_base as (
  select
    r.id as radr_id,
    r.creator_user_id,

    -- creator profile
    cp.profile_photo_url      as creator_profile_photo_url,
    cp.first_name             as creator_first_name,
    cp.last_name              as creator_last_name,
    cp.current_role_title     as creator_current_role_title,
    cp.company                as creator_company,
    cp.bio                    as creator_profile_bio,
    cp.professional_interests as creator_professional_interests,
    cp.personal_interests     as creator_personal_interests,
    cp.tags                   as creator_tags
  from public.radrs r
  join public.profiles cp
    on cp.user_id = r.creator_user_id
  where
    r.id = p_radr_id
    and r.status = 'open'
),
joiners as (
  select
    rus.radr_id,
    rus.user_id as joiner_user_id,

    rus.professional_score,
    rus.personal_score,
    rus.overall_score,
    rus.total_score,
    rus.three_things,
    rus.explanation,
    rus.common_tags,
    rus.status as match_status,

    p.profile_photo_url,
    p.first_name,
    p.last_name,
    p.current_role_title,
    p.company,
    p.bio as profile_bio,
    p.professional_interests,
    p.personal_interests,
    p.tags
  from public.radr_user_scores rus
  join public.profiles p
    on p.user_id = rus.user_id
  where
    rus.radr_id = p_radr_id
    and rus.status = 'active'
)
select jsonb_build_object(
  'radr_id',      rb.radr_id,
  'creator', jsonb_build_object(
    'user_id',                 rb.creator_user_id,
    'profile_photo_url',       rb.creator_profile_photo_url,
    'first_name',              rb.creator_first_name,
    'last_name',               rb.creator_last_name,
    'current_role_title',      rb.creator_current_role_title,
    'company',                 rb.creator_company,
    'bio',                     rb.creator_profile_bio,
    'professional_interests',  rb.creator_professional_interests,
    'personal_interests',      rb.creator_personal_interests,
    'tags',                    rb.creator_tags
  ),
  'joiners', coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'joiner_user_id',        j.joiner_user_id,
          'professional_score',    j.professional_score,
          'personal_score',        j.personal_score,
          'overall_score',         j.overall_score,
          'total_score',           j.total_score,
          'three_things',          j.three_things,
          'explanation',           j.explanation,
          'common_tags',           j.common_tags,
          'match_status',          j.match_status,
          'profile_photo_url',     j.profile_photo_url,
          'first_name',            j.first_name,
          'last_name',             j.last_name,
          'current_role_title',    j.current_role_title,
          'company',               j.company,
          'bio',                   j.profile_bio,
          'professional_interests',j.professional_interests,
          'personal_interests',    j.personal_interests,
          'tags',                  j.tags
        )
      )
      from joiners j
    ),
    '[]'::jsonb
  )
)
from radr_base rb;
$$;


ALTER FUNCTION "public"."get_radr_with_creator_and_joiners"("p_radr_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_radrs_joiners"("p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$
WITH base AS (
  SELECT
    s.total_score  AS _total_score,
    r.created_at   AS _radr_created_at,
    to_jsonb(s)    AS rusr,   -- radr_user_score
    to_jsonb(r)    AS radr,   -- radrs row
    to_jsonb(p)    AS prof    -- creator_profile
  FROM public.radr_user_scores AS s
  JOIN public.radrs AS r
    ON r.id = s.radr_id
  LEFT JOIN public.profiles AS p
    ON p.user_id = r.creator_user_id
  WHERE s.user_id = p_user_id
)
SELECT COALESCE(
  jsonb_agg(
    jsonb_build_object(
      'radr',            radr,
      'creator_profile', prof,
      'radr_user_score', rusr
    )
    ORDER BY _total_score     DESC NULLS LAST,
             _radr_created_at DESC NULLS LAST
  ),
  '[]'::jsonb
)
FROM base;
$$;


ALTER FUNCTION "public"."get_radrs_joiners"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_radrs"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$WITH base AS (
  SELECT
    s.total_score  AS _total_score,
    r.created_at   AS _radr_created_at,
    to_jsonb(s)    AS rusr,   -- radr_user_score
    to_jsonb(r)    AS radr,   -- radrs row
    to_jsonb(p)    AS prof    -- creator_profile
  FROM public.radr_user_scores s
  JOIN public.radrs r
    ON r.id = s.radr_id
  LEFT JOIN public.profiles p
    ON p.user_id = r.creator_user_id
  WHERE s.user_id = auth.uid()
    AND r.status = 'open'

)
SELECT COALESCE(
  jsonb_agg(
    jsonb_build_object(
      'radr',            radr,
      'creator_profile', prof,
      'radr_user_score', rusr
    )
    ORDER BY _total_score DESC NULLS LAST,
             _radr_created_at DESC NULLS LAST
  ),
  '[]'::jsonb
)
FROM base;$$;


ALTER FUNCTION "public"."get_user_radrs"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  insert into public.profiles (user_id) values (new.id);
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."place_checkins_enqueue_scoring"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  -- We only care about present = true
  -- Allow both INSERT and UPDATE (even true -> true) to enqueue
  if NEW.present = true then
    insert into public.jobs (type, status, payload_json)
    values (
      'score_user_for_open_radrs',
      'queued',
      jsonb_build_object(
        'user_id', NEW.user_id,
        'place_id', NEW.place_id
      )
    );
  end if;

  return NEW;
end;
$$;


ALTER FUNCTION "public"."place_checkins_enqueue_scoring"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."place_checkins_on_checkout_close_radrs_scores"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  -- Only act when present changes *to* false
  if new.present = false and (old.present is distinct from false) then
    
    -- Close any radrs owned by this user that are not already closed
    update radrs
    set status = 'closed'
    where creator_user_id = new.user_id
      and status is distinct from 'closed';

    -- Close any user scores for this user that are not already closed
    update radr_user_scores
    set status = 'closed'
    where user_id = new.user_id
      and status is distinct from 'closed';

  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."place_checkins_on_checkout_close_radrs_scores"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."radr_user_scores_on_activate"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  -- Only act when status changes *to* 'active'
  if new.status = 'active' and (old.status is distinct from 'active') then
    
    -- append user to joined_user_ids (avoid duplicates)
    update radrs
    set joined_user_ids = array_append(joined_user_ids, new.user_id)
    where id = new.radr_id
      and not (new.user_id = any (joined_user_ids));

    -- after appending, update status to full when joiners_count reaches capacity
    update radrs
    set status = 'full'
    where id = new.radr_id
      and joiners_count = capacity;

  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."radr_user_scores_on_activate"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."radrs_auto_status"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  -- Don't auto-reopen closed/expired radrs on later updates
  if TG_OP = 'UPDATE' and OLD.status in ('closed', 'expired') then
    return NEW;
  end if;

  -- Expire if we're past expires_at
  if NEW.expires_at is not null and NEW.expires_at <= now() then
    if NEW.status <> 'expired' then
      update radrs
      set status = 'expired'
      where id = NEW.id;
    end if;
    return NEW;
  end if;

  -- At this point, joiners_count has been computed (AFTER trigger),
  -- so you *can* rely on it.
  if NEW.joiners_count >= NEW.capacity then
    if NEW.status <> 'full' then
      update radrs
      set status = 'full'
      where id = NEW.id;
    end if;
  else
    if NEW.status <> 'open' then
      update radrs
      set status = 'open'
      where id = NEW.id;
    end if;
  end if;

  return NEW;
end;
$$;


ALTER FUNCTION "public"."radrs_auto_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."radrs_on_expire_set_scores_expired"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  -- Only act when status changes *to* 'expired'
  if new.status = 'expired' and (old.status is distinct from 'expired') then
    update radr_user_scores
    set status = 'expired'
    where radr_id = new.id
      and status is distinct from 'expired';
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."radrs_on_expire_set_scores_expired"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_expires_at_from_duration"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Ensure created_at is set
  IF NEW.created_at IS NULL THEN
    NEW.created_at := now();
  END IF;

  -- If duration is provided, compute expires_at
  IF NEW.duration IS NOT NULL THEN
    NEW.expires_at := NEW.created_at + (NEW.duration || ' minutes')::interval;
  ELSE
    NEW.expires_at := NULL;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_expires_at_from_duration"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_radr_membership_timestamps"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Row is created already active → user is joining now
    IF NEW.status = 'active' AND NEW.joined_at IS NULL THEN
      NEW.joined_at := now();
    END IF;

  ELSIF TG_OP = 'UPDATE' THEN
    -- Transition into active (join)
    IF OLD.status <> 'active'
       AND NEW.status = 'active'
       AND NEW.joined_at IS NULL THEN
      NEW.joined_at := now();
    END IF;

    -- Transition out of active (leave / close / expire)
    IF OLD.status = 'active'
       AND NEW.status <> 'active' THEN
      NEW.left_at := COALESCE(NEW.left_at, now());
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_radr_membership_timestamps"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin new.updated_at = now(); return new; end $$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_radrs_joined_users"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  IF TG_OP = 'INSERT' THEN
    IF NEW.status = 'active' THEN
      UPDATE public.radrs r
      SET joined_user_ids =
            CASE 
              WHEN NOT (NEW.user_id = ANY(r.joined_user_ids))
              THEN array_append(r.joined_user_ids, NEW.user_id)
              ELSE r.joined_user_ids
            END
      WHERE r.id = NEW.radr_id;
    END IF;

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.status <> 'active' AND NEW.status = 'active' THEN
      UPDATE public.radrs r
      SET joined_user_ids =
            CASE 
              WHEN NOT (NEW.user_id = ANY(r.joined_user_ids))
              THEN array_append(r.joined_user_ids, NEW.user_id)
              ELSE r.joined_user_ids
            END
      WHERE r.id = NEW.radr_id;
    END IF;

    IF OLD.status = 'active' AND NEW.status <> 'active' THEN
      UPDATE public.radrs r
      SET joined_user_ids = array_remove(r.joined_user_ids, NEW.user_id)
      WHERE r.id = NEW.radr_id;
    END IF;
  END IF;

  RETURN NEW;
end;
$$;


ALTER FUNCTION "public"."sync_radrs_joined_users"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_place_present_count"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if TG_OP = 'INSERT' then
    -- new checkin created
    if NEW.present then
      update public.places
      set present_count = present_count + 1
      where id = NEW.place_id;
    end if;

    return NEW;

  elsif TG_OP = 'UPDATE' then
    -- only care if present flips
    if coalesce(OLD.present, false) = false
       and coalesce(NEW.present, false) = true then
      -- false -> true : increment
      update public.places
      set present_count = present_count + 1
      where id = NEW.place_id;

    elsif coalesce(OLD.present, false) = true
          and coalesce(NEW.present, false) = false then
      -- true -> false : decrement
      update public.places
      set present_count = present_count - 1
      where id = NEW.place_id;
    end if;

    return NEW;

  elsif TG_OP = 'DELETE' then
    -- checkin removed; if it was counted, decrement
    if OLD.present then
      update public.places
      set present_count = present_count - 1
      where id = OLD.place_id;
    end if;

    return OLD;
  end if;

  return NULL;
end;
$$;


ALTER FUNCTION "public"."update_place_present_count"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."user_has_active_place_checkin"("p_user_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  select exists (
    select 1
    from public.place_checkins pc
    where pc.user_id = p_user_id
      and pc.present is true
  );
$$;


ALTER FUNCTION "public"."user_has_active_place_checkin"("p_user_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."companies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."companies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."company_members" (
    "company_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" DEFAULT 'member'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "company_members_role_check" CHECK (("role" = ANY (ARRAY['owner'::"text", 'admin'::"text", 'member'::"text"])))
);


ALTER TABLE "public"."company_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."jobs" (
    "id" bigint NOT NULL,
    "type" "text" NOT NULL,
    "payload_json" "jsonb" NOT NULL,
    "status" "text" DEFAULT 'queued'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "last_error" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "jobs_status_check" CHECK (("status" = ANY (ARRAY['queued'::"text", 'running'::"text", 'succeeded'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."jobs" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."jobs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."jobs_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."jobs_id_seq" OWNED BY "public"."jobs"."id";



CREATE TABLE IF NOT EXISTS "public"."place_checkins" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "place_id" "uuid" NOT NULL,
    "intentions" "text"[],
    "checkin_time" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "present" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."place_checkins" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."places" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "lat" double precision NOT NULL,
    "lon" double precision NOT NULL,
    "radius_m" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "active_users" numeric,
    "present_count" integer DEFAULT 0 NOT NULL,
    "company_id" "uuid",
    CONSTRAINT "places_radius_m_check" CHECK (("radius_m" > 0))
);


ALTER TABLE "public"."places" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "user_id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "profile_photo_url" "text",
    "current_role_title" "text",
    "past_experience" "text",
    "future_career_aspirations" "text",
    "professional_interests" "text"[],
    "professional_values" "text"[],
    "personal_interests" "text"[],
    "extracurriculars" "text"[],
    "tags" "text"[],
    "keywords_20" "text"[],
    "keywords_3" "text"[],
    "bio" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "active_location_id" "uuid",
    "geo_verified" boolean,
    "geo_verified_at" timestamp with time zone,
    "last_gps_lat" double precision,
    "last_gps_lon" double precision,
    "first_name" "text",
    "last_name" "text",
    "company" "text"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."radr_embeddings" (
    "radr_id" "uuid" NOT NULL,
    "prof_vec" "public"."vector"(768),
    "personal_vec" "public"."vector"(768),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "profile_vec" "public"."vector"(768)
);


ALTER TABLE "public"."radr_embeddings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."radr_user_scores" (
    "radr_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "professional_score" real NOT NULL,
    "personal_score" real NOT NULL,
    "overall_score" real NOT NULL,
    "total_score" real NOT NULL,
    "three_things" "text"[],
    "explanation" "jsonb",
    "common_tags" "text"[],
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "joined_at" timestamp with time zone,
    "left_at" timestamp with time zone,
    CONSTRAINT "radr_user_scores_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'active'::"text", 'closed'::"text", 'expired'::"text"])))
);


ALTER TABLE "public"."radr_user_scores" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."radrs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "creator_user_id" "uuid" NOT NULL,
    "place_id" "uuid" NOT NULL,
    "intentions" "text",
    "expires_at" timestamp with time zone,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "bio" "text",
    "capacity" integer DEFAULT 2 NOT NULL,
    "joined_user_ids" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "joiners_count" integer GENERATED ALWAYS AS ("cardinality"("joined_user_ids")) STORED,
    "duration" integer DEFAULT 0 NOT NULL,
    "instructions" "text" DEFAULT ''::"text" NOT NULL,
    CONSTRAINT "radrs_capacity_check" CHECK (("joiners_count" <= "capacity")),
    CONSTRAINT "radrs_no_creator_in_joiners" CHECK ((NOT ("creator_user_id" = ANY ("joined_user_ids")))),
    CONSTRAINT "radrs_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'full'::"text", 'closed'::"text", 'expired'::"text"])))
);


ALTER TABLE "public"."radrs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."support_requests" (
    "id" bigint NOT NULL,
    "user_id" "uuid" DEFAULT "auth"."uid"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "email" "text",
    "request" "text" DEFAULT ''::"text"
);


ALTER TABLE "public"."support_requests" OWNER TO "postgres";


ALTER TABLE "public"."support_requests" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."support_requests_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."user_embeddings" (
    "user_id" "uuid" NOT NULL,
    "prof_vec" "public"."vector"(768),
    "personal_vec" "public"."vector"(768),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "profile_vec" "public"."vector"(768)
);


ALTER TABLE "public"."user_embeddings" OWNER TO "postgres";


ALTER TABLE ONLY "public"."jobs" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."jobs_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."companies"
    ADD CONSTRAINT "companies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."companies"
    ADD CONSTRAINT "companies_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."company_members"
    ADD CONSTRAINT "company_members_pkey" PRIMARY KEY ("company_id", "user_id");



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."place_checkins"
    ADD CONSTRAINT "place_checkins_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."places"
    ADD CONSTRAINT "places_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."radr_embeddings"
    ADD CONSTRAINT "radr_embeddings_pkey" PRIMARY KEY ("radr_id");



ALTER TABLE ONLY "public"."radr_user_scores"
    ADD CONSTRAINT "radr_user_scores_pkey" PRIMARY KEY ("radr_id", "user_id");



ALTER TABLE ONLY "public"."radrs"
    ADD CONSTRAINT "radrs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."support_requests"
    ADD CONSTRAINT "support_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_embeddings"
    ADD CONSTRAINT "user_embeddings_pkey" PRIMARY KEY ("user_id");



CREATE INDEX "idx_company_members_user" ON "public"."company_members" USING "btree" ("user_id");



CREATE INDEX "idx_place_checkins_place_time" ON "public"."place_checkins" USING "btree" ("place_id", "checkin_time" DESC);



CREATE INDEX "idx_place_checkins_user_time" ON "public"."place_checkins" USING "btree" ("user_id", "checkin_time" DESC);



CREATE INDEX "idx_places_company" ON "public"."places" USING "btree" ("company_id");



CREATE INDEX "idx_profiles_keywords20_gin" ON "public"."profiles" USING "gin" ("keywords_20");



CREATE INDEX "idx_profiles_keywords3_gin" ON "public"."profiles" USING "gin" ("keywords_3");



CREATE INDEX "idx_profiles_tags_gin" ON "public"."profiles" USING "gin" ("tags");



CREATE INDEX "idx_radrs_creator" ON "public"."radrs" USING "btree" ("creator_user_id");



CREATE INDEX "idx_radrs_place_status" ON "public"."radrs" USING "btree" ("place_id", "status");



CREATE INDEX "idx_rus_radr" ON "public"."radr_user_scores" USING "btree" ("radr_id");



CREATE INDEX "idx_rus_status" ON "public"."radr_user_scores" USING "btree" ("status");



CREATE INDEX "idx_rus_user" ON "public"."radr_user_scores" USING "btree" ("user_id");



CREATE INDEX "idx_rus_user_score" ON "public"."radr_user_scores" USING "btree" ("user_id", "total_score" DESC);



CREATE INDEX "idx_user_embeddings_career_ann" ON "public"."user_embeddings" USING "ivfflat" ("prof_vec" "public"."vector_cosine_ops") WITH ("lists"='100');



CREATE INDEX "idx_user_embeddings_interests_ann" ON "public"."user_embeddings" USING "ivfflat" ("personal_vec" "public"."vector_cosine_ops") WITH ("lists"='100');



CREATE UNIQUE INDEX "radrs_one_active_per_user" ON "public"."radrs" USING "btree" ("creator_user_id") WHERE ("status" = ANY (ARRAY['open'::"text", 'full'::"text"]));



CREATE UNIQUE INDEX "uniq_jobs_compute_embeddings_active_per_user" ON "public"."jobs" USING "btree" ((("payload_json" ->> 'user_id'::"text"))) WHERE (("type" = 'compute_embeddings'::"text") AND ("status" = ANY (ARRAY['queued'::"text", 'running'::"text"])));



CREATE UNIQUE INDEX "uniq_place_checkin_user_place" ON "public"."place_checkins" USING "btree" ("user_id", "place_id");



CREATE OR REPLACE TRIGGER "trg_jobs_updated" BEFORE UPDATE ON "public"."jobs" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_place_checkins_enqueue_scoring" AFTER INSERT OR UPDATE OF "present" ON "public"."place_checkins" FOR EACH ROW WHEN (("new"."present" = true)) EXECUTE FUNCTION "public"."place_checkins_enqueue_scoring"();



CREATE OR REPLACE TRIGGER "trg_place_checkins_ensure_single_present" BEFORE INSERT OR UPDATE OF "present" ON "public"."place_checkins" FOR EACH ROW WHEN (("new"."present" = true)) EXECUTE FUNCTION "public"."ensure_single_present_checkin_per_user"();



CREATE OR REPLACE TRIGGER "trg_place_checkins_on_checkout_close_radrs_scores" AFTER UPDATE OF "present" ON "public"."place_checkins" FOR EACH ROW WHEN (("new"."present" = false)) EXECUTE FUNCTION "public"."place_checkins_on_checkout_close_radrs_scores"();



CREATE OR REPLACE TRIGGER "trg_place_checkins_present_count" AFTER INSERT OR DELETE OR UPDATE ON "public"."place_checkins" FOR EACH ROW EXECUTE FUNCTION "public"."update_place_present_count"();



CREATE OR REPLACE TRIGGER "trg_place_checkins_updated" BEFORE UPDATE ON "public"."place_checkins" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_places_updated" BEFORE UPDATE ON "public"."places" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_profiles_enqueue_embeddings" AFTER INSERT OR UPDATE OF "current_role_title", "past_experience", "future_career_aspirations", "professional_values", "professional_interests", "personal_interests", "extracurriculars" ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."enqueue_compute_embeddings_on_profile_change"();



CREATE OR REPLACE TRIGGER "trg_profiles_updated" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_radr_embeddings_updated" BEFORE UPDATE ON "public"."radr_embeddings" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_radr_membership_timestamps" BEFORE INSERT OR UPDATE ON "public"."radr_user_scores" FOR EACH ROW EXECUTE FUNCTION "public"."set_radr_membership_timestamps"();



CREATE OR REPLACE TRIGGER "trg_radr_user_scores_updated" BEFORE UPDATE ON "public"."radr_user_scores" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_radrs_auto_status" AFTER INSERT OR UPDATE OF "joined_user_ids", "capacity", "expires_at" ON "public"."radrs" FOR EACH ROW EXECUTE FUNCTION "public"."radrs_auto_status"();



CREATE OR REPLACE TRIGGER "trg_radrs_close_pending_when_full" AFTER UPDATE OF "status" ON "public"."radrs" FOR EACH ROW WHEN (("new"."status" = 'full'::"text")) EXECUTE FUNCTION "public"."close_pending_matches_when_full"();



CREATE OR REPLACE TRIGGER "trg_radrs_close_scores_when_closed" AFTER UPDATE ON "public"."radrs" FOR EACH ROW EXECUTE FUNCTION "public"."close_scores_when_radr_closed"();



CREATE OR REPLACE TRIGGER "trg_radrs_enqueue_embeddings" AFTER INSERT OR UPDATE OF "intentions", "bio" ON "public"."radrs" FOR EACH ROW EXECUTE FUNCTION "public"."enqueue_build_radr_embeddings"();



CREATE OR REPLACE TRIGGER "trg_radrs_on_expire_scores" AFTER UPDATE OF "status" ON "public"."radrs" FOR EACH ROW WHEN (("new"."status" = 'expired'::"text")) EXECUTE FUNCTION "public"."radrs_on_expire_set_scores_expired"();



CREATE OR REPLACE TRIGGER "trg_radrs_set_expires_at" BEFORE INSERT OR UPDATE OF "duration", "created_at" ON "public"."radrs" FOR EACH ROW EXECUTE FUNCTION "public"."set_expires_at_from_duration"();



CREATE OR REPLACE TRIGGER "trg_radrs_updated" BEFORE UPDATE ON "public"."radrs" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_sync_radrs_joined_users" AFTER INSERT OR UPDATE OF "status" ON "public"."radr_user_scores" FOR EACH ROW EXECUTE FUNCTION "public"."sync_radrs_joined_users"();



CREATE OR REPLACE TRIGGER "trg_user_embeddings_updated" BEFORE UPDATE ON "public"."user_embeddings" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



ALTER TABLE ONLY "public"."company_members"
    ADD CONSTRAINT "company_members_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."company_members"
    ADD CONSTRAINT "company_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."place_checkins"
    ADD CONSTRAINT "place_checkins_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."place_checkins"
    ADD CONSTRAINT "place_checkins_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."places"
    ADD CONSTRAINT "places_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."radr_embeddings"
    ADD CONSTRAINT "radr_embeddings_radr_id_fkey" FOREIGN KEY ("radr_id") REFERENCES "public"."radrs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."radr_user_scores"
    ADD CONSTRAINT "radr_user_scores_radr_id_fkey" FOREIGN KEY ("radr_id") REFERENCES "public"."radrs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."radr_user_scores"
    ADD CONSTRAINT "radr_user_scores_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."radrs"
    ADD CONSTRAINT "radrs_creator_user_id_fkey" FOREIGN KEY ("creator_user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."radrs"
    ADD CONSTRAINT "radrs_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_embeddings"
    ADD CONSTRAINT "user_embeddings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Enable insert for authenticated users only" ON "public"."company_members" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."radrs" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."support_requests" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable read access for all users" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."radr_user_scores" FOR SELECT USING (true);



CREATE POLICY "Users can insert their own profile" ON "public"."profiles" FOR INSERT WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can update their own profile" ON "public"."profiles" FOR UPDATE USING (("user_id" = "auth"."uid"()));



CREATE POLICY "checkins_self_ins" ON "public"."place_checkins" FOR INSERT WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "checkins_self_sel" ON "public"."place_checkins" FOR SELECT USING (("user_id" = "auth"."uid"()));



CREATE POLICY "checkins_self_upd" ON "public"."place_checkins" FOR UPDATE USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."company_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "embeddings_self_select" ON "public"."user_embeddings" FOR SELECT USING (("user_id" = "auth"."uid"()));



CREATE POLICY "embeddings_self_update" ON "public"."user_embeddings" FOR UPDATE USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "embeddings_self_upsert" ON "public"."user_embeddings" FOR INSERT WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."jobs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."place_checkins" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."places" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "places_read_authenticated" ON "public"."places" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."radr_embeddings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."radr_user_scores" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."radrs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "radrs_select_open_or_participant" ON "public"."radrs" FOR SELECT USING ((("status" = 'open'::"text") OR ("auth"."uid"() = "creator_user_id") OR ("auth"."uid"() = ANY ("joined_user_ids"))));



CREATE POLICY "radrs_update_owner" ON "public"."radrs" FOR UPDATE USING (("auth"."uid"() = "creator_user_id"));



ALTER TABLE "public"."support_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_embeddings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "viewer or radr_creator can update scores" ON "public"."radr_user_scores" FOR UPDATE USING ((("auth"."uid"() = "user_id") OR ("auth"."uid"() = ( SELECT "radrs"."creator_user_id"
   FROM "public"."radrs"
  WHERE ("radrs"."id" = "radr_user_scores"."radr_id"))))) WITH CHECK ((("auth"."uid"() = "user_id") OR ("auth"."uid"() = ( SELECT "radrs"."creator_user_id"
   FROM "public"."radrs"
  WHERE ("radrs"."id" = "radr_user_scores"."radr_id")))));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";








GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext"(character) TO "postgres";
GRANT ALL ON FUNCTION "public"."citext"(character) TO "anon";
GRANT ALL ON FUNCTION "public"."citext"(character) TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext"(character) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext"("inet") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext"("inet") TO "anon";
GRANT ALL ON FUNCTION "public"."citext"("inet") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext"("inet") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "service_role";














































































































































































GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."close_pending_matches_when_full"() TO "anon";
GRANT ALL ON FUNCTION "public"."close_pending_matches_when_full"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."close_pending_matches_when_full"() TO "service_role";



GRANT ALL ON FUNCTION "public"."close_scores_when_radr_closed"() TO "anon";
GRANT ALL ON FUNCTION "public"."close_scores_when_radr_closed"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."close_scores_when_radr_closed"() TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."enqueue_build_radr_embeddings"() TO "anon";
GRANT ALL ON FUNCTION "public"."enqueue_build_radr_embeddings"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enqueue_build_radr_embeddings"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enqueue_compute_embeddings_on_profile_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."enqueue_compute_embeddings_on_profile_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enqueue_compute_embeddings_on_profile_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."ensure_single_present_checkin_per_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."ensure_single_present_checkin_per_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_single_present_checkin_per_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_open_radr_joiners"("p_creator_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_open_radr_joiners"("p_creator_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_open_radr_joiners"("p_creator_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_place_checkin_count"("_place_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_place_checkin_count"("_place_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_place_checkin_count"("_place_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_place_checkin_count"("_place_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_places_for_dropdown"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_places_for_dropdown"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_places_for_dropdown"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_radr_details"("p_radr_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_radr_details"("p_radr_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_radr_details"("p_radr_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_radr_details_for_joiner"("p_radr_id" "uuid", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_radr_details_for_joiner"("p_radr_id" "uuid", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_radr_details_for_joiner"("p_radr_id" "uuid", "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_radr_profiles_with_flag"("p_radr_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_radr_profiles_with_flag"("p_radr_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_radr_profiles_with_flag"("p_radr_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_radr_with_creator_and_joiners"("p_radr_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_radr_with_creator_and_joiners"("p_radr_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_radr_with_creator_and_joiners"("p_radr_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_radrs_joiners"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_radrs_joiners"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_radrs_joiners"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_radrs"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_radrs"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_radrs"() TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."place_checkins_enqueue_scoring"() TO "anon";
GRANT ALL ON FUNCTION "public"."place_checkins_enqueue_scoring"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."place_checkins_enqueue_scoring"() TO "service_role";



GRANT ALL ON FUNCTION "public"."place_checkins_on_checkout_close_radrs_scores"() TO "anon";
GRANT ALL ON FUNCTION "public"."place_checkins_on_checkout_close_radrs_scores"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."place_checkins_on_checkout_close_radrs_scores"() TO "service_role";



GRANT ALL ON FUNCTION "public"."radr_user_scores_on_activate"() TO "anon";
GRANT ALL ON FUNCTION "public"."radr_user_scores_on_activate"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."radr_user_scores_on_activate"() TO "service_role";



GRANT ALL ON FUNCTION "public"."radrs_auto_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."radrs_auto_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."radrs_auto_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."radrs_on_expire_set_scores_expired"() TO "anon";
GRANT ALL ON FUNCTION "public"."radrs_on_expire_set_scores_expired"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."radrs_on_expire_set_scores_expired"() TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_expires_at_from_duration"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_expires_at_from_duration"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_expires_at_from_duration"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_radr_membership_timestamps"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_radr_membership_timestamps"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_radr_membership_timestamps"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_radrs_joined_users"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_radrs_joined_users"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_radrs_joined_users"() TO "service_role";



GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_place_present_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_place_present_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_place_present_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."user_has_active_place_checkin"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."user_has_active_place_checkin"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_has_active_place_checkin"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "service_role";












GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "service_role";















GRANT ALL ON TABLE "public"."companies" TO "anon";
GRANT ALL ON TABLE "public"."companies" TO "authenticated";
GRANT ALL ON TABLE "public"."companies" TO "service_role";



GRANT ALL ON TABLE "public"."company_members" TO "anon";
GRANT ALL ON TABLE "public"."company_members" TO "authenticated";
GRANT ALL ON TABLE "public"."company_members" TO "service_role";



GRANT ALL ON TABLE "public"."jobs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."jobs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."jobs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."jobs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."place_checkins" TO "anon";
GRANT ALL ON TABLE "public"."place_checkins" TO "authenticated";
GRANT ALL ON TABLE "public"."place_checkins" TO "service_role";



GRANT ALL ON TABLE "public"."places" TO "anon";
GRANT ALL ON TABLE "public"."places" TO "authenticated";
GRANT ALL ON TABLE "public"."places" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."radr_embeddings" TO "anon";
GRANT ALL ON TABLE "public"."radr_embeddings" TO "authenticated";
GRANT ALL ON TABLE "public"."radr_embeddings" TO "service_role";



GRANT ALL ON TABLE "public"."radr_user_scores" TO "anon";
GRANT ALL ON TABLE "public"."radr_user_scores" TO "authenticated";
GRANT ALL ON TABLE "public"."radr_user_scores" TO "service_role";



GRANT ALL ON TABLE "public"."radrs" TO "anon";
GRANT ALL ON TABLE "public"."radrs" TO "authenticated";
GRANT ALL ON TABLE "public"."radrs" TO "service_role";



GRANT ALL ON TABLE "public"."support_requests" TO "anon";
GRANT ALL ON TABLE "public"."support_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."support_requests" TO "service_role";



GRANT ALL ON SEQUENCE "public"."support_requests_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."support_requests_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."support_requests_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."user_embeddings" TO "anon";
GRANT ALL ON TABLE "public"."user_embeddings" TO "authenticated";
GRANT ALL ON TABLE "public"."user_embeddings" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































revoke delete on table "public"."jobs" from "anon";

revoke insert on table "public"."jobs" from "anon";

revoke references on table "public"."jobs" from "anon";

revoke select on table "public"."jobs" from "anon";

revoke trigger on table "public"."jobs" from "anon";

revoke truncate on table "public"."jobs" from "anon";

revoke update on table "public"."jobs" from "anon";

revoke delete on table "public"."jobs" from "authenticated";

revoke insert on table "public"."jobs" from "authenticated";

revoke references on table "public"."jobs" from "authenticated";

revoke select on table "public"."jobs" from "authenticated";

revoke trigger on table "public"."jobs" from "authenticated";

revoke truncate on table "public"."jobs" from "authenticated";

revoke update on table "public"."jobs" from "authenticated";

CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

CREATE TRIGGER "CV Upload Hook" AFTER INSERT ON storage.buckets FOR EACH ROW EXECUTE FUNCTION supabase_functions.http_request('https://sogerjzdsfxfpuufvwcx.supabase.co/functions/v1/quick-handler', 'POST', '{"Content-type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNvZ2Vyanpkc2Z4ZnB1dWZ2d2N4Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1OTE2MTYxOCwiZXhwIjoyMDc0NzM3NjE4fQ.lF5a1wtuKcEbwKjjsbb1G8a1pxaPVyOCtAT1nVsv6Yw","x-webhook-secret":"1B0j3o5Sb3eL7Ofrdf3AmYS8GnfCQAZK"}', '{}', '5000');


