set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.close_pending_matches_when_full()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.close_scores_when_radr_closed()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.enqueue_build_radr_embeddings()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.enqueue_compute_embeddings_on_profile_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.ensure_single_present_checkin_per_user()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_open_radr_joiners(p_creator_user_id uuid)
 RETURNS TABLE(radr_id uuid, creator_user_id uuid, joiner_user_id uuid, professional_score real, personal_score real, overall_score real, total_score real, three_things text[], explanation jsonb, common_tags text[], match_status text, profile_photo_url text, first_name text, last_name text, current_role_title text, company text, profile_bio text, professional_interests text[], personal_interests text[], tags text[])
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_place_checkin_count(_place_id uuid)
 RETURNS integer
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT count(*)::integer
  FROM place_checkins
  WHERE place_id = _place_id
    AND present = TRUE;
$function$
;

CREATE OR REPLACE FUNCTION public.get_places_for_dropdown()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_radr_details(p_radr_id uuid)
 RETURNS TABLE(radr_id uuid, instructions text, bio text)
 LANGUAGE sql
 STABLE
AS $function$
  select
    id          as radr_id,
    instructions,
    bio
  from public.radrs
  where id = p_radr_id;
$function$
;

CREATE OR REPLACE FUNCTION public.get_radr_details_for_joiner(p_radr_id uuid, p_user_id uuid)
 RETURNS TABLE(radr_id uuid, user_id uuid, creator boolean, professional_score numeric, personal_score numeric, overall_score numeric, total_score numeric, three_things text[], explanation jsonb, common_tags text[], match_status text, profile_photo_url text, first_name text, last_name text, current_role_title text, company text, profile_bio text, professional_interests text[], personal_interests text[], tags text[])
 LANGUAGE sql
 STABLE
AS $function$

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

$function$
;

CREATE OR REPLACE FUNCTION public.get_radr_profiles_with_flag(p_radr_id uuid)
 RETURNS TABLE(radr_id uuid, user_id uuid, creator boolean, professional_score numeric, personal_score numeric, overall_score numeric, total_score numeric, three_things text[], explanation jsonb, common_tags text[], match_status text, profile_photo_url text, first_name text, last_name text, current_role_title text, company text, profile_bio text, professional_interests text[], personal_interests text[], tags text[])
 LANGUAGE sql
 STABLE
AS $function$select *
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
  order by creator desc;  -- creator first, then joiners$function$
;

CREATE OR REPLACE FUNCTION public.get_radr_with_creator_and_joiners(p_radr_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_radrs_joiners(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_user_radrs()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$WITH base AS (
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
FROM base;$function$
;

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
begin
  insert into public.profiles (user_id) values (new.id);
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.place_checkins_enqueue_scoring()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.place_checkins_on_checkout_close_radrs_scores()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.radr_user_scores_on_activate()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.radrs_auto_status()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.radrs_on_expire_set_scores_expired()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.set_expires_at_from_duration()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.set_radr_membership_timestamps()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin new.updated_at = now(); return new; end $function$
;

CREATE OR REPLACE FUNCTION public.sync_radrs_joined_users()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.update_place_present_count()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.user_has_active_place_checkin(p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select exists (
    select 1
    from public.place_checkins pc
    where pc.user_id = p_user_id
      and pc.present is true
  );
$function$
;


