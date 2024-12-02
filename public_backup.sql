--
-- PostgreSQL database dump
--

-- Dumped from database version 17.1 (Debian 17.1-1.pgdg120+1)
-- Dumped by pg_dump version 17.1 (Debian 17.1-1.pgdg120+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: pg_database_owner
--

CREATE SCHEMA public;


ALTER SCHEMA public OWNER TO pg_database_owner;

--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: pg_database_owner
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: command_kind; Type: TYPE; Schema: public; Owner: root
--

CREATE TYPE public.command_kind AS ENUM (
    'SQL',
    'PROGRAM',
    'BUILTIN'
);


ALTER TYPE public.command_kind OWNER TO root;

--
-- Name: log_type; Type: TYPE; Schema: public; Owner: root
--

CREATE TYPE public.log_type AS ENUM (
    'DEBUG',
    'NOTICE',
    'INFO',
    'ERROR',
    'PANIC',
    'USER'
);


ALTER TYPE public.log_type OWNER TO root;

--
-- Name: regular_good; Type: TYPE; Schema: public; Owner: root
--

CREATE TYPE public.regular_good AS ENUM (
    'ximang',
    'trobay'
);


ALTER TYPE public.regular_good OWNER TO root;

--
-- Name: trans_role; Type: TYPE; Schema: public; Owner: root
--

CREATE TYPE public.trans_role AS ENUM (
    'customer',
    'driver',
    'owner'
);


ALTER TYPE public.trans_role OWNER TO root;

--
-- Name: trans_status; Type: TYPE; Schema: public; Owner: root
--

CREATE TYPE public.trans_status AS ENUM (
    'pending',
    'success',
    'failed',
    'cancel',
    'unpaid',
    'partial',
    'unknown'
);


ALTER TYPE public.trans_status OWNER TO root;

--
-- Name: trans_type; Type: TYPE; Schema: public; Owner: root
--

CREATE TYPE public.trans_type AS ENUM (
    'income',
    'outcome'
);


ALTER TYPE public.trans_type OWNER TO root;

--
-- Name: _validate_json_schema_type(text, jsonb); Type: FUNCTION; Schema: public; Owner: root
--

CREATE FUNCTION public._validate_json_schema_type(type text, data jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
  IF type = 'integer' THEN
    IF jsonb_typeof(data) != 'number' THEN
      RETURN false;
END IF;
    IF trunc(data::text::numeric) != data::text::numeric THEN
      RETURN false;
END IF;
ELSE
    IF type != jsonb_typeof(data) THEN
      RETURN false;
END IF;
END IF;
RETURN true;
END;
$$;


ALTER FUNCTION public._validate_json_schema_type(type text, data jsonb) OWNER TO root;

--
-- Name: cron_days(timestamp with time zone, integer[], integer[], integer[]); Type: FUNCTION; Schema: public; Owner: root
--

CREATE FUNCTION public.cron_days(from_ts timestamp with time zone, allowed_months integer[], allowed_days integer[], allowed_week_days integer[]) RETURNS SETOF timestamp with time zone
    LANGUAGE sql STRICT
    AS $$
    WITH
    ad(ad) AS (SELECT UNNEST(allowed_days)),
    am(am) AS (SELECT * FROM timetable.cron_months(from_ts, allowed_months)),
    gend(ts) AS ( --generated days
        SELECT date_trunc('day', ts)
        FROM am,
            pg_catalog.generate_series(am.am, am.am + INTERVAL '1 month'
                - INTERVAL '1 day',  -- don't include the same day of the next month
                INTERVAL '1 day') g(ts)
    )
SELECT ts
FROM gend JOIN ad ON date_part('day', gend.ts) = ad.ad
WHERE extract(dow from ts)=ANY(allowed_week_days)
    $$;


ALTER FUNCTION public.cron_days(from_ts timestamp with time zone, allowed_months integer[], allowed_days integer[], allowed_week_days integer[]) OWNER TO root;

--
-- Name: cron_months(timestamp with time zone, integer[]); Type: FUNCTION; Schema: public; Owner: root
--

CREATE FUNCTION public.cron_months(from_ts timestamp with time zone, allowed_months integer[]) RETURNS SETOF timestamp with time zone
    LANGUAGE sql STRICT
    AS $$
    WITH
    am(am) AS (SELECT UNNEST(allowed_months)),
    genm(ts) AS ( --generated months
        SELECT date_trunc('month', ts)
        FROM pg_catalog.generate_series(from_ts, from_ts + INTERVAL '1 year', INTERVAL '1 month') g(ts)
    )
SELECT ts FROM genm JOIN am ON date_part('month', genm.ts) = am.am
    $$;


ALTER FUNCTION public.cron_months(from_ts timestamp with time zone, allowed_months integer[]) OWNER TO root;

--
-- Name: cron_runs(timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: root
--

CREATE FUNCTION public.cron_runs(from_ts timestamp with time zone, cron text) RETURNS SETOF timestamp with time zone
    LANGUAGE sql STRICT
    AS $$
SELECT cd + ct
FROM
    timetable.cron_split_to_arrays(cron) a,
    timetable.cron_times(a.hours, a.mins) ct CROSS JOIN
    timetable.cron_days(from_ts, a.months, a.days, a.dow) cd
WHERE cd + ct > from_ts
ORDER BY 1 ASC;
$$;


ALTER FUNCTION public.cron_runs(from_ts timestamp with time zone, cron text) OWNER TO root;

--
-- Name: cron_split_to_arrays(text); Type: FUNCTION; Schema: public; Owner: root
--

CREATE FUNCTION public.cron_split_to_arrays(cron text, OUT mins integer[], OUT hours integer[], OUT days integer[], OUT months integer[], OUT dow integer[]) RETURNS record
    LANGUAGE plpgsql STRICT
    AS $_$
DECLARE
a_element text[];
    i_index integer;
    a_tmp text[];
    tmp_item text;
    a_range int[];
    a_split text[];
    a_res integer[];
    max_val integer;
    min_val integer;
    dimensions constant text[] = '{"minutes", "hours", "days", "months", "days of week"}';
    allowed_ranges constant integer[][] = '{{0,59},{0,23},{1,31},{1,12},{0,7}}';
BEGIN
    a_element := regexp_split_to_array(cron, '\s+');
FOR i_index IN 1..5 LOOP
        a_res := NULL;
        a_tmp := string_to_array(a_element[i_index],',');
        FOREACH  tmp_item IN ARRAY a_tmp LOOP
            IF tmp_item ~ '^[0-9]+$' THEN -- normal integer
                a_res := array_append(a_res, tmp_item::int);
            ELSIF tmp_item ~ '^[*]+$' THEN -- '*' any value
                a_range := array(select generate_series(allowed_ranges[i_index][1], allowed_ranges[i_index][2]));
                a_res := array_cat(a_res, a_range);
            ELSIF tmp_item ~ '^[0-9]+[-][0-9]+$' THEN -- '-' range of values
                a_range := regexp_split_to_array(tmp_item, '-');
                a_range := array(select generate_series(a_range[1], a_range[2]));
                a_res := array_cat(a_res, a_range);
            ELSIF tmp_item ~ '^[0-9]+[\/][0-9]+$' THEN -- '/' step values
                a_range := regexp_split_to_array(tmp_item, '/');
                a_range := array(select generate_series(a_range[1], allowed_ranges[i_index][2], a_range[2]));
                a_res := array_cat(a_res, a_range);
            ELSIF tmp_item ~ '^[0-9-]+[\/][0-9]+$' THEN -- '-' range of values and '/' step values
                a_split := regexp_split_to_array(tmp_item, '/');
                a_range := regexp_split_to_array(a_split[1], '-');
                a_range := array(select generate_series(a_range[1], a_range[2], a_split[2]::int));
                a_res := array_cat(a_res, a_range);
            ELSIF tmp_item ~ '^[*]+[\/][0-9]+$' THEN -- '*' any value and '/' step values
                a_split := regexp_split_to_array(tmp_item, '/');
                a_range := array(select generate_series(allowed_ranges[i_index][1], allowed_ranges[i_index][2], a_split[2]::int));
                a_res := array_cat(a_res, a_range);
ELSE
                RAISE EXCEPTION 'Value ("%") not recognized', a_element[i_index]
                    USING HINT = 'fields separated by space or tab.'+
                       'Values allowed: numbers (value list with ","), '+
                    'any value with "*", range of value with "-" and step values with "/"!';
END IF;
END LOOP;
SELECT
    ARRAY_AGG(x.val), MIN(x.val), MAX(x.val) INTO a_res, min_val, max_val
FROM (
         SELECT DISTINCT UNNEST(a_res) AS val ORDER BY val) AS x;
IF max_val > allowed_ranges[i_index][2] OR min_val < allowed_ranges[i_index][1] OR a_res IS NULL THEN
            RAISE EXCEPTION '% is out of range % for %', tmp_item, allowed_ranges[i_index:i_index][:], dimensions[i_index];
END IF;
CASE i_index
            WHEN 1 THEN mins := a_res;
WHEN 2 THEN hours := a_res;
WHEN 3 THEN days := a_res;
WHEN 4 THEN months := a_res;
ELSE
            dow := a_res;
END CASE;
END LOOP;
    RETURN;
END;
$_$;


ALTER FUNCTION public.cron_split_to_arrays(cron text, OUT mins integer[], OUT hours integer[], OUT days integer[], OUT months integer[], OUT dow integer[]) OWNER TO root;

--
-- Name: cron_times(integer[], integer[]); Type: FUNCTION; Schema: public; Owner: root
--

CREATE FUNCTION public.cron_times(allowed_hours integer[], allowed_minutes integer[]) RETURNS SETOF time without time zone
    LANGUAGE sql STRICT
    AS $$
    WITH
    ah(ah) AS (SELECT UNNEST(allowed_hours)),
    am(am) AS (SELECT UNNEST(allowed_minutes))
SELECT make_time(ah.ah, am.am, 0) FROM ah CROSS JOIN am
    $$;


ALTER FUNCTION public.cron_times(allowed_hours integer[], allowed_minutes integer[]) OWNER TO root;

--
-- Name: delete_job(text); Type: FUNCTION; Schema: public; Owner: root
--

CREATE FUNCTION public.delete_job(job_name text) RETURNS boolean
    LANGUAGE sql
    AS $_$
    WITH del_chain AS (DELETE FROM timetable.chain WHERE chain.chain_name = $1 RETURNING chain_id)
SELECT EXISTS(SELECT 1 FROM del_chain)
           $_$;


ALTER FUNCTION public.delete_job(job_name text) OWNER TO root;

--
-- Name: FUNCTION delete_job(job_name text); Type: COMMENT; Schema: public; Owner: root
--

COMMENT ON FUNCTION public.delete_job(job_name text) IS 'Delete the chain and its tasks from the system';


--
-- Name: delete_task(bigint); Type: FUNCTION; Schema: public; Owner: root
--

CREATE FUNCTION public.delete_task(task_id bigint) RETURNS boolean
    LANGUAGE sql
    AS $_$
    WITH del_task AS (DELETE FROM timetable.task WHERE task_id = $1 RETURNING task_id)
SELECT EXISTS(SELECT 1 FROM del_task)
           $_$;


ALTER FUNCTION public.delete_task(task_id bigint) OWNER TO root;

--
-- Name: FUNCTION delete_task(task_id bigint); Type: COMMENT; Schema: public; Owner: root
--

COMMENT ON FUNCTION public.delete_task(task_id bigint) IS 'Delete the task from a chain';


--
-- Name: get_client_name(integer); Type: FUNCTION; Schema: public; Owner: root
--

CREATE FUNCTION public.get_client_name(integer) RETURNS text
    LANGUAGE sql
    AS $_$
SELECT client_name FROM timetable.active_session WHERE server_pid = $1 LIMIT 1
$_$;


ALTER FUNCTION public.get_client_name(integer) OWNER TO root;

--
-- Name: move_task_down(bigint); Type: FUNCTION; Schema: public; Owner: root
--

CREATE FUNCTION public.move_task_down(task_id bigint) RETURNS boolean
    LANGUAGE sql
    AS $_$
	WITH current_task (ct_chain_id, ct_id, ct_order) AS (
		SELECT chain_id, task_id, task_order FROM timetable.task WHERE task_id = $1
	),
	tasks(t_id, t_new_order) AS (
		SELECT task_id, COALESCE(LAG(task_order) OVER w, LEAD(task_order) OVER w)
		FROM timetable.task t, current_task ct
		WHERE chain_id = ct_chain_id AND (task_order > ct_order OR task_id = ct_id)
		WINDOW w AS (PARTITION BY chain_id ORDER BY ABS(task_order - ct_order))
		LIMIT 2
	),
	upd AS (
		UPDATE timetable.task t SET task_order = t_new_order
		FROM tasks WHERE tasks.t_id = t.task_id AND tasks.t_new_order IS NOT NULL
		RETURNING true
	)
SELECT COUNT(*) > 0 FROM upd
                             $_$;


ALTER FUNCTION public.move_task_down(task_id bigint) OWNER TO root;

--
-- Name: FUNCTION move_task_down(task_id bigint); Type: COMMENT; Schema: public; Owner: root
--

COMMENT ON FUNCTION public.move_task_down(task_id bigint) IS 'Switch the order of the task execution with a following task within the chain';


--
-- Name: move_task_up(bigint); Type: FUNCTION; Schema: public; Owner: root
--

CREATE FUNCTION public.move_task_up(task_id bigint) RETURNS boolean
    LANGUAGE sql
    AS $_$
	WITH current_task (ct_chain_id, ct_id, ct_order) AS (
		SELECT chain_id, task_id, task_order FROM timetable.task WHERE task_id = $1
	),
	tasks(t_id, t_new_order) AS (
		SELECT task_id, COALESCE(LAG(task_order) OVER w, LEAD(task_order) OVER w)
		FROM timetable.task t, current_task ct
		WHERE chain_id = ct_chain_id AND (task_order < ct_order OR task_id = ct_id)
		WINDOW w AS (PARTITION BY chain_id ORDER BY ABS(task_order - ct_order))
		LIMIT 2
	),
	upd AS (
		UPDATE timetable.task t SET task_order = t_new_order
		FROM tasks WHERE tasks.t_id = t.task_id AND tasks.t_new_order IS NOT NULL
		RETURNING true
	)
SELECT COUNT(*) > 0 FROM upd
                             $_$;


ALTER FUNCTION public.move_task_up(task_id bigint) OWNER TO root;

--
-- Name: FUNCTION move_task_up(task_id bigint); Type: COMMENT; Schema: public; Owner: root
--

COMMENT ON FUNCTION public.move_task_up(task_id bigint) IS 'Switch the order of the task execution with a previous task within the chain';


--
-- Name: notify_chain_start(bigint, text, interval); Type: FUNCTION; Schema: public; Owner: root
--

CREATE FUNCTION public.notify_chain_start(chain_id bigint, worker_name text, start_delay interval DEFAULT NULL::interval) RETURNS void
    LANGUAGE sql
    AS $$
SELECT pg_notify(
               worker_name,
               format('{"ConfigID": %s, "Command": "START", "Ts": %s, "Delay": %s}',
                      chain_id,
                      EXTRACT(epoch FROM clock_timestamp())::bigint,
                      COALESCE(EXTRACT(epoch FROM start_delay)::bigint, 0)
               )
       )
           $$;


ALTER FUNCTION public.notify_chain_start(chain_id bigint, worker_name text, start_delay interval) OWNER TO root;

--
-- Name: FUNCTION notify_chain_start(chain_id bigint, worker_name text, start_delay interval); Type: COMMENT; Schema: public; Owner: root
--

COMMENT ON FUNCTION public.notify_chain_start(chain_id bigint, worker_name text, start_delay interval) IS 'Send notification to the worker to start the chain';


--
-- Name: notify_chain_stop(bigint, text); Type: FUNCTION; Schema: public; Owner: root
--

CREATE FUNCTION public.notify_chain_stop(chain_id bigint, worker_name text) RETURNS void
    LANGUAGE sql
    AS $$
SELECT pg_notify(
               worker_name,
               format('{"ConfigID": %s, "Command": "STOP", "Ts": %s}',
                      chain_id,
                      EXTRACT(epoch FROM clock_timestamp())::bigint)
       )
           $$;


ALTER FUNCTION public.notify_chain_stop(chain_id bigint, worker_name text) OWNER TO root;

--
-- Name: FUNCTION notify_chain_stop(chain_id bigint, worker_name text); Type: COMMENT; Schema: public; Owner: root
--

COMMENT ON FUNCTION public.notify_chain_stop(chain_id bigint, worker_name text) IS 'Send notification to the worker to stop the chain';


--
-- Name: try_lock_client_name(bigint, text); Type: FUNCTION; Schema: public; Owner: root
--

CREATE FUNCTION public.try_lock_client_name(worker_pid bigint, worker_name text) RETURNS boolean
    LANGUAGE plpgsql STRICT
    AS $$
BEGIN
    IF pg_is_in_recovery() THEN
        RAISE NOTICE 'Cannot obtain lock on a replica. Please, use the primary node';
RETURN FALSE;
END IF;
    -- remove disconnected sessions
DELETE
FROM timetable.active_session
WHERE server_pid NOT IN (
    SELECT pid
    FROM pg_catalog.pg_stat_activity
    WHERE application_name = 'pg_timetable'
);
DELETE
FROM timetable.active_chain
WHERE client_name NOT IN (
    SELECT client_name FROM timetable.active_session
);
-- check if there any active sessions with the client name but different client pid
PERFORM 1
        FROM timetable.active_session s
        WHERE
            s.client_pid <> worker_pid
            AND s.client_name = worker_name
        LIMIT 1;
    IF FOUND THEN
        RAISE NOTICE 'Another client is already connected to server with name: %', worker_name;
RETURN FALSE;
END IF;
    -- insert current session information
INSERT INTO timetable.active_session(client_pid, client_name, server_pid) VALUES (worker_pid, worker_name, pg_backend_pid());
RETURN TRUE;
END;
$$;


ALTER FUNCTION public.try_lock_client_name(worker_pid bigint, worker_name text) OWNER TO root;

--
-- Name: validate_json_schema(jsonb, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: root
--

CREATE FUNCTION public.validate_json_schema(schema jsonb, data jsonb, root_schema jsonb DEFAULT NULL::jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
DECLARE
prop text;
  item jsonb;
  path text[];
  types text[];
  pattern text;
  props text[];
BEGIN

  IF root_schema IS NULL THEN
    root_schema = schema;
END IF;

  IF schema ? 'type' THEN
    IF jsonb_typeof(schema->'type') = 'array' THEN
      types = ARRAY(SELECT jsonb_array_elements_text(schema->'type'));
ELSE
      types = ARRAY[schema->>'type'];
END IF;
    IF (SELECT NOT bool_or(timetable._validate_json_schema_type(type, data)) FROM unnest(types) type) THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'properties' THEN
    FOR prop IN SELECT jsonb_object_keys(schema->'properties') LOOP
                         IF data ? prop AND NOT timetable.validate_json_schema(schema->'properties'->prop, data->prop, root_schema) THEN
        RETURN false;
END IF;
END LOOP;
END IF;

  IF schema ? 'required' AND jsonb_typeof(data) = 'object' THEN
    IF NOT ARRAY(SELECT jsonb_object_keys(data)) @>
           ARRAY(SELECT jsonb_array_elements_text(schema->'required')) THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'items' AND jsonb_typeof(data) = 'array' THEN
    IF jsonb_typeof(schema->'items') = 'object' THEN
      FOR item IN SELECT jsonb_array_elements(data) LOOP
                           IF NOT timetable.validate_json_schema(schema->'items', item, root_schema) THEN
          RETURN false;
END IF;
END LOOP;
ELSE
      IF NOT (
        SELECT bool_and(i > jsonb_array_length(schema->'items') OR timetable.validate_json_schema(schema->'items'->(i::int - 1), elem, root_schema))
        FROM jsonb_array_elements(data) WITH ORDINALITY AS t(elem, i)
      ) THEN
        RETURN false;
END IF;
END IF;
END IF;

  IF jsonb_typeof(schema->'additionalItems') = 'boolean' and NOT (schema->'additionalItems')::text::boolean AND jsonb_typeof(schema->'items') = 'array' THEN
    IF jsonb_array_length(data) > jsonb_array_length(schema->'items') THEN
      RETURN false;
END IF;
END IF;

  IF jsonb_typeof(schema->'additionalItems') = 'object' THEN
    IF NOT (
        SELECT bool_and(timetable.validate_json_schema(schema->'additionalItems', elem, root_schema))
        FROM jsonb_array_elements(data) WITH ORDINALITY AS t(elem, i)
        WHERE i > jsonb_array_length(schema->'items')
      ) THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'minimum' AND jsonb_typeof(data) = 'number' THEN
    IF data::text::numeric < (schema->>'minimum')::numeric THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'maximum' AND jsonb_typeof(data) = 'number' THEN
    IF data::text::numeric > (schema->>'maximum')::numeric THEN
      RETURN false;
END IF;
END IF;

  IF COALESCE((schema->'exclusiveMinimum')::text::bool, FALSE) THEN
    IF data::text::numeric = (schema->>'minimum')::numeric THEN
      RETURN false;
END IF;
END IF;

  IF COALESCE((schema->'exclusiveMaximum')::text::bool, FALSE) THEN
    IF data::text::numeric = (schema->>'maximum')::numeric THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'anyOf' THEN
    IF NOT (SELECT bool_or(timetable.validate_json_schema(sub_schema, data, root_schema)) FROM jsonb_array_elements(schema->'anyOf') sub_schema) THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'allOf' THEN
    IF NOT (SELECT bool_and(timetable.validate_json_schema(sub_schema, data, root_schema)) FROM jsonb_array_elements(schema->'allOf') sub_schema) THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'oneOf' THEN
    IF 1 != (SELECT COUNT(*) FROM jsonb_array_elements(schema->'oneOf') sub_schema WHERE timetable.validate_json_schema(sub_schema, data, root_schema)) THEN
      RETURN false;
END IF;
END IF;

  IF COALESCE((schema->'uniqueItems')::text::boolean, false) THEN
    IF (SELECT COUNT(*) FROM jsonb_array_elements(data)) != (SELECT count(DISTINCT val) FROM jsonb_array_elements(data) val) THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'additionalProperties' AND jsonb_typeof(data) = 'object' THEN
    props := ARRAY(
      SELECT key
      FROM jsonb_object_keys(data) key
      WHERE key NOT IN (SELECT jsonb_object_keys(schema->'properties'))
        AND NOT EXISTS (SELECT * FROM jsonb_object_keys(schema->'patternProperties') pat WHERE key ~ pat)
    );
    IF jsonb_typeof(schema->'additionalProperties') = 'boolean' THEN
      IF NOT (schema->'additionalProperties')::text::boolean AND jsonb_typeof(data) = 'object' AND NOT props <@ ARRAY(SELECT jsonb_object_keys(schema->'properties')) THEN
        RETURN false;
END IF;
    ELSEIF NOT (
      SELECT bool_and(timetable.validate_json_schema(schema->'additionalProperties', data->key, root_schema))
      FROM unnest(props) key
    ) THEN
      RETURN false;
END IF;
END IF;

  IF schema ? '$ref' THEN
    path := ARRAY(
      SELECT regexp_replace(regexp_replace(path_part, '~1', '/'), '~0', '~')
      FROM UNNEST(regexp_split_to_array(schema->>'$ref', '/')) path_part
    );
    -- ASSERT path[1] = '#', 'only refs anchored at the root are supported';
    IF NOT timetable.validate_json_schema(root_schema #> path[2:array_length(path, 1)], data, root_schema) THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'enum' THEN
    IF NOT EXISTS (SELECT * FROM jsonb_array_elements(schema->'enum') val WHERE val = data) THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'minLength' AND jsonb_typeof(data) = 'string' THEN
    IF char_length(data #>> '{}') < (schema->>'minLength')::numeric THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'maxLength' AND jsonb_typeof(data) = 'string' THEN
    IF char_length(data #>> '{}') > (schema->>'maxLength')::numeric THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'not' THEN
    IF timetable.validate_json_schema(schema->'not', data, root_schema) THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'maxProperties' AND jsonb_typeof(data) = 'object' THEN
    IF (SELECT count(*) FROM jsonb_object_keys(data)) > (schema->>'maxProperties')::numeric THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'minProperties' AND jsonb_typeof(data) = 'object' THEN
    IF (SELECT count(*) FROM jsonb_object_keys(data)) < (schema->>'minProperties')::numeric THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'maxItems' AND jsonb_typeof(data) = 'array' THEN
    IF (SELECT count(*) FROM jsonb_array_elements(data)) > (schema->>'maxItems')::numeric THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'minItems' AND jsonb_typeof(data) = 'array' THEN
    IF (SELECT count(*) FROM jsonb_array_elements(data)) < (schema->>'minItems')::numeric THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'dependencies' THEN
    FOR prop IN SELECT jsonb_object_keys(schema->'dependencies') LOOP
                         IF data ? prop THEN
        IF jsonb_typeof(schema->'dependencies'->prop) = 'array' THEN
          IF NOT (SELECT bool_and(data ? dep) FROM jsonb_array_elements_text(schema->'dependencies'->prop) dep) THEN
            RETURN false;
END IF;
ELSE
          IF NOT timetable.validate_json_schema(schema->'dependencies'->prop, data, root_schema) THEN
            RETURN false;
END IF;
END IF;
END IF;
END LOOP;
END IF;

  IF schema ? 'pattern' AND jsonb_typeof(data) = 'string' THEN
    IF (data #>> '{}') !~ (schema->>'pattern') THEN
      RETURN false;
END IF;
END IF;

  IF schema ? 'patternProperties' AND jsonb_typeof(data) = 'object' THEN
    FOR prop IN SELECT jsonb_object_keys(data) LOOP
                             FOR pattern IN SELECT jsonb_object_keys(schema->'patternProperties') LOOP
                         RAISE NOTICE 'prop %s, pattern %, schema %', prop, pattern, schema->'patternProperties'->pattern;
IF prop ~ pattern AND NOT timetable.validate_json_schema(schema->'patternProperties'->pattern, data->prop, root_schema) THEN
          RETURN false;
END IF;
END LOOP;
END LOOP;
END IF;

  IF schema ? 'multipleOf' AND jsonb_typeof(data) = 'number' THEN
    IF data::text::numeric % (schema->>'multipleOf')::numeric != 0 THEN
      RETURN false;
END IF;
END IF;

RETURN true;
END;
$_$;


ALTER FUNCTION public.validate_json_schema(schema jsonb, data jsonb, root_schema jsonb) OWNER TO root;

--
-- Name: accounting_vouchers_id_seq1; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.accounting_vouchers_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.accounting_vouchers_id_seq1 OWNER TO root;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: assigned_to; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.assigned_to (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    task_id bigint NOT NULL,
    user_id bigint NOT NULL,
    status text NOT NULL,
    description text,
    date_assigned text,
    deadline text,
    company_id bigint
);


ALTER TABLE public.assigned_to OWNER TO root;

--
-- Name: assigned_to_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.assigned_to_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.assigned_to_id_seq OWNER TO root;

--
-- Name: assigned_to_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.assigned_to_id_seq OWNED BY public.assigned_to.id;


--
-- Name: balances_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.balances_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.balances_id_seq OWNER TO root;

--
-- Name: cancellation_drivers; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.cancellation_drivers (
    truck_id bigint,
    pre_order_id text,
    deleted_at timestamp with time zone,
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.cancellation_drivers OWNER TO root;

--
-- Name: cancellation_drivers_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.cancellation_drivers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.cancellation_drivers_id_seq OWNER TO root;

--
-- Name: cancellation_drivers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.cancellation_drivers_id_seq OWNED BY public.cancellation_drivers.id;


--
-- Name: company; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.company (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    name character varying(255) NOT NULL,
    description text,
    company_code character varying(255)
);


ALTER TABLE public.company OWNER TO root;

--
-- Name: company_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.company_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.company_id_seq OWNER TO root;

--
-- Name: company_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.company_id_seq OWNED BY public.company.id;


--
-- Name: customer_address; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.customer_address (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    customer_id bigint,
    contact_name character varying(100) NOT NULL,
    address_phone_number character varying(20),
    province character varying(10),
    district character varying(10),
    ward character varying(10),
    detail_address text,
    lat character varying(255),
    long character varying(255),
    is_default boolean DEFAULT false
);


ALTER TABLE public.customer_address OWNER TO root;

--
-- Name: customer_address_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.customer_address_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customer_address_id_seq OWNER TO root;

--
-- Name: customer_address_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.customer_address_id_seq OWNED BY public.customer_address.id;


--
-- Name: customer_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.customer_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customer_id_seq OWNER TO root;

--
-- Name: customer_products; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.customer_products (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    customer_id bigint NOT NULL,
    product_id bigint NOT NULL,
    price numeric(15,2) NOT NULL
);


ALTER TABLE public.customer_products OWNER TO root;

--
-- Name: customer_products_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.customer_products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customer_products_id_seq OWNER TO root;

--
-- Name: customer_products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.customer_products_id_seq OWNED BY public.customer_products.id;


--
-- Name: customer_routes; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.customer_routes (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    customer_id bigint NOT NULL,
    name character varying(150) NOT NULL,
    address_from_id bigint NOT NULL,
    address_to_id bigint NOT NULL,
    route_pricing numeric(15,2) NOT NULL,
    driver_pricing numeric(15,2) NOT NULL,
    distance numeric(15,2) NOT NULL
);


ALTER TABLE public.customer_routes OWNER TO root;

--
-- Name: customer_routes_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.customer_routes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customer_routes_id_seq OWNER TO root;

--
-- Name: customer_routes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.customer_routes_id_seq OWNED BY public.customer_routes.id;


--
-- Name: customers; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.customers (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    customer_name character varying(255) NOT NULL,
    email character varying(255) NOT NULL,
    phone_number character varying(20) NOT NULL,
    company_name character varying(255),
    tax_code character varying(20),
    description text
);


ALTER TABLE public.customers OWNER TO root;

--
-- Name: customers_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.customers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customers_id_seq OWNER TO root;

--
-- Name: customers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.customers_id_seq OWNED BY public.customers.id;


--
-- Name: delivery_order_details_id_seq1; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.delivery_order_details_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.delivery_order_details_id_seq1 OWNER TO root;

--
-- Name: delivery_orders_id_seq1; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.delivery_orders_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.delivery_orders_id_seq1 OWNER TO root;

--
-- Name: department; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.department (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    name character varying(255) NOT NULL,
    description text,
    company_id bigint
);


ALTER TABLE public.department OWNER TO root;

--
-- Name: department_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.department_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.department_id_seq OWNER TO root;

--
-- Name: department_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.department_id_seq OWNED BY public.department.id;


--
-- Name: drivers; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.drivers (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    owner_id bigint NOT NULL,
    name character varying(100) NOT NULL,
    day_of_birth character varying(100),
    phone_number character varying(20),
    email character varying(150) NOT NULL,
    password text NOT NULL,
    media_license_front text,
    media_license_back text,
    province character varying(10),
    district character varying(10),
    ward character varying(10),
    detail_address text,
    lat character varying(255),
    long character varying(255),
    start_date character varying(100),
    vehicle_id bigint NOT NULL,
    driver_status character varying(100) DEFAULT 'inactive'::character varying NOT NULL
);


ALTER TABLE public.drivers OWNER TO root;

--
-- Name: drivers_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.drivers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.drivers_id_seq OWNER TO root;

--
-- Name: drivers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.drivers_id_seq OWNED BY public.drivers.id;


--
-- Name: driving_car; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.driving_car (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    owner_car_id bigint,
    driving_name character varying(100),
    driving_license character varying(255),
    driving_address character varying(255),
    driving_phone character varying(255),
    email character varying(255),
    password_driving character varying(255),
    media_license_front_id bigint,
    media_license_back_id bigint,
    province character varying(255),
    district character varying(255),
    ward character varying(255),
    device_token text,
    driving_license_front character varying,
    driving_license_back character varying(50),
    year_of_exp bigint
);


ALTER TABLE public.driving_car OWNER TO root;

--
-- Name: driving_car_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.driving_car_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.driving_car_id_seq OWNER TO root;

--
-- Name: driving_car_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.driving_car_id_seq OWNED BY public.driving_car.id;


--
-- Name: driving_car_id_seq1; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.driving_car_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.driving_car_id_seq1 OWNER TO root;

--
-- Name: formulas; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.formulas (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    owner_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    owner_formula text NOT NULL
);


ALTER TABLE public.formulas OWNER TO root;

--
-- Name: formulas_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.formulas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.formulas_id_seq OWNER TO root;

--
-- Name: formulas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.formulas_id_seq OWNED BY public.formulas.id;


--
-- Name: internal_customer; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.internal_customer (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    customer_name character varying(255) NOT NULL,
    email character varying(255) NOT NULL,
    phone_number character varying(20) NOT NULL,
    company_name character varying(255),
    tax_code character varying(20),
    description text
);


ALTER TABLE public.internal_customer OWNER TO root;

--
-- Name: internal_customer_address; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.internal_customer_address (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    internal_customer_id bigint,
    contact_name character varying(255) NOT NULL,
    address_phone_number character varying(20),
    price_service numeric(10,2) NOT NULL,
    province character varying(255),
    district character varying(255),
    ward character varying(255),
    detail_address text,
    lat character varying(255),
    long character varying(255),
    is_default boolean DEFAULT false
);


ALTER TABLE public.internal_customer_address OWNER TO root;

--
-- Name: internal_customer_address_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.internal_customer_address_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.internal_customer_address_id_seq OWNER TO root;

--
-- Name: internal_customer_address_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.internal_customer_address_id_seq OWNED BY public.internal_customer_address.id;


--
-- Name: internal_customer_good_type; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.internal_customer_good_type (
    internal_good_type_id bigint NOT NULL,
    internal_customer_id bigint NOT NULL,
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone
);


ALTER TABLE public.internal_customer_good_type OWNER TO root;

--
-- Name: internal_customer_good_type_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.internal_customer_good_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.internal_customer_good_type_id_seq OWNER TO root;

--
-- Name: internal_customer_good_type_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.internal_customer_good_type_id_seq OWNED BY public.internal_customer_good_type.id;


--
-- Name: internal_customer_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.internal_customer_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.internal_customer_id_seq OWNER TO root;

--
-- Name: internal_customer_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.internal_customer_id_seq OWNED BY public.internal_customer.id;


--
-- Name: internal_good_type; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.internal_good_type (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    name character varying(255) NOT NULL,
    description text
);


ALTER TABLE public.internal_good_type OWNER TO root;

--
-- Name: internal_good_type_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.internal_good_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.internal_good_type_id_seq OWNER TO root;

--
-- Name: internal_good_type_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.internal_good_type_id_seq OWNED BY public.internal_good_type.id;


--
-- Name: internal_order_media; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.internal_order_media (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    order_id bigint NOT NULL,
    media_id bigint NOT NULL,
    user_role_id bigint NOT NULL,
    user_role character varying(255) NOT NULL,
    order_status bigint NOT NULL,
    media_name character varying(255) NOT NULL
);


ALTER TABLE public.internal_order_media OWNER TO root;

--
-- Name: internal_order_media_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.internal_order_media_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.internal_order_media_id_seq OWNER TO root;

--
-- Name: internal_order_media_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.internal_order_media_id_seq OWNED BY public.internal_order_media.id;


--
-- Name: internal_orders; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.internal_orders (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    order_code character varying(255),
    owner_car_id bigint,
    customer_id bigint,
    customer_address_id bigint,
    warehouse_id bigint,
    truck_id bigint,
    driver_id bigint,
    weight numeric(10,2),
    price numeric(15,2),
    vat numeric(10,2),
    status bigint,
    description text,
    project_process numeric(10,2),
    order_type bigint,
    order_name character varying(255) DEFAULT NULL::character varying
);


ALTER TABLE public.internal_orders OWNER TO root;

--
-- Name: internal_orders_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.internal_orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.internal_orders_id_seq OWNER TO root;

--
-- Name: internal_orders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.internal_orders_id_seq OWNED BY public.internal_orders.id;


--
-- Name: internal_warehouse; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.internal_warehouse (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    name character varying(255),
    address_phone_number character varying(20),
    province character varying(255),
    district character varying(255),
    ward character varying(255),
    detail_address text,
    lat character varying(255),
    long character varying(255),
    description text,
    price_router numeric(10,2),
    warehouse_status character varying(255) DEFAULT 'empty'::character varying
);


ALTER TABLE public.internal_warehouse OWNER TO root;

--
-- Name: internal_warehouse_good_type; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.internal_warehouse_good_type (
    internal_good_type_id bigint NOT NULL,
    internal_warehouse_id bigint NOT NULL,
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone
);


ALTER TABLE public.internal_warehouse_good_type OWNER TO root;

--
-- Name: internal_warehouse_good_type_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.internal_warehouse_good_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.internal_warehouse_good_type_id_seq OWNER TO root;

--
-- Name: internal_warehouse_good_type_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.internal_warehouse_good_type_id_seq OWNED BY public.internal_warehouse_good_type.id;


--
-- Name: internal_warehouse_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.internal_warehouse_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.internal_warehouse_id_seq OWNER TO root;

--
-- Name: internal_warehouse_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.internal_warehouse_id_seq OWNED BY public.internal_warehouse.id;


--
-- Name: inventory_products_id_seq1; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.inventory_products_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.inventory_products_id_seq1 OWNER TO root;

--
-- Name: managers; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.managers (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    full_name text,
    birthday text,
    cccd bigint,
    date_range_cccd text,
    place_range_cccd text,
    owner_address text,
    email text,
    manager_password text,
    phone_number text,
    device_token text,
    role character varying(10) DEFAULT 'manager'::character varying,
    owner_car_id bigint NOT NULL
);


ALTER TABLE public.managers OWNER TO root;

--
-- Name: managers_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.managers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.managers_id_seq OWNER TO root;

--
-- Name: managers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.managers_id_seq OWNED BY public.managers.id;


--
-- Name: media; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.media (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    media_url text NOT NULL,
    media_format character varying(50) DEFAULT 'jpg'::character varying NOT NULL,
    media_size numeric(10,2) NOT NULL,
    media_width bigint NOT NULL,
    media_height bigint NOT NULL,
    media_hash character varying(64) DEFAULT NULL::character varying
);


ALTER TABLE public.media OWNER TO root;

--
-- Name: media_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.media_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.media_id_seq OWNER TO root;

--
-- Name: media_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.media_id_seq OWNED BY public.media.id;


--
-- Name: migrations; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.migrations (
    id character varying(255) NOT NULL
);


ALTER TABLE public.migrations OWNER TO root;

--
-- Name: object_images; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.object_images (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    object_id bigint NOT NULL,
    object character varying(255) NOT NULL,
    image_url text NOT NULL,
    purpose character varying(255) NOT NULL,
    parent_id bigint,
    uploader_id bigint,
    uploader_role character varying(255) DEFAULT NULL::character varying
);


ALTER TABLE public.object_images OWNER TO root;

--
-- Name: object_images_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.object_images_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.object_images_id_seq OWNER TO root;

--
-- Name: object_images_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.object_images_id_seq OWNED BY public.object_images.id;


--
-- Name: operators; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.operators (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    symbol character varying(1) NOT NULL,
    code character varying(10) NOT NULL
);


ALTER TABLE public.operators OWNER TO root;

--
-- Name: operators_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.operators_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.operators_id_seq OWNER TO root;

--
-- Name: operators_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.operators_id_seq OWNED BY public.operators.id;


--
-- Name: order_customer; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.order_customer (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    pre_order_id character varying(255),
    owner_car_id bigint,
    customer_id bigint,
    truck_id bigint,
    name_customer_to character varying(255),
    name_customer_from character varying(255),
    phone_number_customer_to character varying(20),
    phone_number_customer_from character varying(20),
    order_type character varying(50),
    quantity bigint DEFAULT 1,
    kg character varying(50),
    price_router character varying(50),
    status bigint DEFAULT 0,
    time_pick character varying(50),
    note text,
    address_to character varying(255),
    address_from character varying(255),
    list_driver jsonb,
    time_order_delivered character varying(50),
    lat_from character varying(50),
    time_order_in_transit character varying(50),
    time_order_canceled character varying(50),
    long_to character varying(50),
    time_order_assigned character varying(50),
    long_from character varying(50),
    time_order_paid character varying(50),
    time_order_arrived character varying(50),
    lat_to character varying(50),
    time_order_init character varying(50),
    cancel_person character varying(255),
    cancel_person_id bigint,
    cancel_reason text,
    cancel_status bigint,
    price_router_vat character varying(50)
);


ALTER TABLE public.order_customer OWNER TO root;

--
-- Name: order_customer_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.order_customer_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.order_customer_id_seq OWNER TO root;

--
-- Name: order_customer_id_seq1; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.order_customer_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.order_customer_id_seq1 OWNER TO root;

--
-- Name: order_customer_id_seq1; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.order_customer_id_seq1 OWNED BY public.order_customer.id;


--
-- Name: orders; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.orders (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    order_name character varying(255) DEFAULT NULL::character varying,
    order_code character varying(255) NOT NULL,
    customer_id bigint NOT NULL,
    customer_name character varying(255) NOT NULL,
    route_id bigint,
    route_pricing numeric(15,2),
    driver_pricing numeric(15,2),
    address_id_from bigint NOT NULL,
    contact_name_from character varying(100) NOT NULL,
    address_phone_number_from character varying(20),
    province_from character varying(10),
    district_from character varying(10),
    ward_from character varying(10),
    detail_address_from text,
    lat_from character varying(255),
    long_from character varying(255),
    address_id_to bigint NOT NULL,
    contact_name_to character varying(100) NOT NULL,
    address_phone_number_to character varying(20),
    province_to character varying(10),
    district_to character varying(10),
    ward_to character varying(10),
    detail_address_to text,
    lat_to character varying(255),
    long_to character varying(255),
    quantity numeric(15,2) NOT NULL,
    status bigint,
    description text,
    extra_fee numeric(15,2) DEFAULT NULL::numeric,
    vat boolean DEFAULT false,
    vat_percent numeric(15,2),
    vat_fee numeric(15,2),
    order_pricing numeric(15,2),
    product_id bigint NOT NULL,
    product_name character varying(255) NOT NULL,
    product_price numeric(15,2),
    total_product_price numeric(15,2) NOT NULL,
    company_name character varying(255),
    tax_code character varying(20),
    driver_id bigint,
    name_driver character varying(255),
    vehicle_id bigint,
    vehicle_plate character varying(50),
    additional_plate character varying(50),
    formular boolean DEFAULT false,
    order_type bigint,
    project_process numeric(10,2) DEFAULT NULL::numeric,
    transport_fee numeric(15,2),
    product_unit character varying(50),
    order_distance numeric(15,2),
    real_quantity numeric(15,2) DEFAULT NULL::numeric
);


ALTER TABLE public.orders OWNER TO root;

--
-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.orders_id_seq OWNER TO root;

--
-- Name: orders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.orders_id_seq OWNED BY public.orders.id;


--
-- Name: owner_car; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.owner_car (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    owner_name character varying(255) NOT NULL,
    birthday text,
    cccd character varying(255) NOT NULL,
    date_range_cccd character varying(255) NOT NULL,
    place_range_cccd character varying(255) NOT NULL,
    owner_address text NOT NULL,
    email character varying(255) NOT NULL,
    owner_password text NOT NULL,
    phone_number character varying(20),
    role character varying(100) DEFAULT 'admin'::character varying
);


ALTER TABLE public.owner_car OWNER TO root;

--
-- Name: owner_car_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.owner_car_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.owner_car_id_seq OWNER TO root;

--
-- Name: owner_car_id_seq1; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.owner_car_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.owner_car_id_seq1 OWNER TO root;

--
-- Name: owner_car_id_seq1; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.owner_car_id_seq1 OWNED BY public.owner_car.id;


--
-- Name: payment_informations_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.payment_informations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.payment_informations_id_seq OWNER TO root;

--
-- Name: permission; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.permission (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    permission_name character varying(255) NOT NULL,
    description text,
    company_id bigint
);


ALTER TABLE public.permission OWNER TO root;

--
-- Name: permission_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.permission_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.permission_id_seq OWNER TO root;

--
-- Name: permission_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.permission_id_seq OWNED BY public.permission.id;


--
-- Name: product_vehicle_types; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.product_vehicle_types (
    product_id bigint NOT NULL,
    vehicle_type_id bigint NOT NULL
);


ALTER TABLE public.product_vehicle_types OWNER TO root;

--
-- Name: products; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.products (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    name character varying(150) NOT NULL,
    unit character varying(50) NOT NULL,
    vehicle_type_id bigint
);


ALTER TABLE public.products OWNER TO root;

--
-- Name: products_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.products_id_seq OWNER TO root;

--
-- Name: products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.products_id_seq OWNED BY public.products.id;


--
-- Name: products_id_seq1; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.products_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.products_id_seq1 OWNER TO root;

--
-- Name: purchase_proposal_details_id_seq1; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.purchase_proposal_details_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchase_proposal_details_id_seq1 OWNER TO root;

--
-- Name: purchase_proposals_id_seq1; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.purchase_proposals_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.purchase_proposals_id_seq1 OWNER TO root;

--
-- Name: ratings; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.ratings (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    pre_order_id text NOT NULL,
    rating_score_customer bigint,
    rating_comment_customer text,
    rating_score_owner bigint,
    rating_comment_owner text
);


ALTER TABLE public.ratings OWNER TO root;

--
-- Name: ratings_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.ratings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.ratings_id_seq OWNER TO root;

--
-- Name: ratings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.ratings_id_seq OWNED BY public.ratings.id;


--
-- Name: receipt_details_id_seq1; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.receipt_details_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.receipt_details_id_seq1 OWNER TO root;

--
-- Name: receipts_id_seq1; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.receipts_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.receipts_id_seq1 OWNER TO root;

--
-- Name: role; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.role (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    role_name character varying(255) NOT NULL,
    role_level bigint NOT NULL,
    description text,
    company_id bigint
);


ALTER TABLE public.role OWNER TO root;

--
-- Name: role_departments; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.role_departments (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    role_id bigint NOT NULL,
    department_id bigint NOT NULL
);


ALTER TABLE public.role_departments OWNER TO root;

--
-- Name: role_departments_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.role_departments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.role_departments_id_seq OWNER TO root;

--
-- Name: role_departments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.role_departments_id_seq OWNED BY public.role_departments.id;


--
-- Name: role_hierarchies; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.role_hierarchies (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    department_id bigint NOT NULL,
    manager_role_id bigint NOT NULL,
    subordinate_role_id bigint NOT NULL
);


ALTER TABLE public.role_hierarchies OWNER TO root;

--
-- Name: role_hierarchies_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.role_hierarchies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.role_hierarchies_id_seq OWNER TO root;

--
-- Name: role_hierarchies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.role_hierarchies_id_seq OWNED BY public.role_hierarchies.id;


--
-- Name: role_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.role_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.role_id_seq OWNER TO root;

--
-- Name: role_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.role_id_seq OWNED BY public.role.id;


--
-- Name: role_permission; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.role_permission (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    role_id bigint NOT NULL,
    permission_id bigint NOT NULL,
    company_id bigint NOT NULL
);


ALTER TABLE public.role_permission OWNER TO root;

--
-- Name: role_permission_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.role_permission_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.role_permission_id_seq OWNER TO root;

--
-- Name: role_permission_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.role_permission_id_seq OWNED BY public.role_permission.id;


--
-- Name: suppliers_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.suppliers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.suppliers_id_seq OWNER TO root;

--
-- Name: task; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.task (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    title character varying(255) NOT NULL,
    description text,
    assigned_by bigint,
    status text,
    company_id bigint,
    repeat character varying(50),
    department_id bigint,
    deadline text,
    date_assigned text,
    task_process text[]
);


ALTER TABLE public.task OWNER TO root;

--
-- Name: task_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.task_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.task_id_seq OWNER TO root;

--
-- Name: task_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.task_id_seq OWNED BY public.task.id;


--
-- Name: task_process; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.task_process (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    step bigint,
    task_process_detail text,
    status boolean DEFAULT false,
    task_id bigint NOT NULL
);


ALTER TABLE public.task_process OWNER TO root;

--
-- Name: task_process_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.task_process_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.task_process_id_seq OWNER TO root;

--
-- Name: task_process_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.task_process_id_seq OWNED BY public.task_process.id;


--
-- Name: transactions; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.transactions (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    internal_order_id bigint NOT NULL,
    user_role_id bigint NOT NULL,
    user_role public.trans_role NOT NULL,
    transaction_type public.trans_type NOT NULL,
    price_router numeric(15,2) NOT NULL,
    transaction_status public.trans_status NOT NULL,
    order_type boolean DEFAULT false
);


ALTER TABLE public.transactions OWNER TO root;

--
-- Name: transactions_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.transactions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.transactions_id_seq OWNER TO root;

--
-- Name: transactions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.transactions_id_seq OWNED BY public.transactions.id;


--
-- Name: truck_car; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.truck_car (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    owner_car_id bigint NOT NULL,
    type_car character varying(255) NOT NULL,
    label_car character varying(255),
    license_car character varying(255) NOT NULL,
    weight_car numeric(15,2),
    address_to character varying(255),
    address_from character varying(255),
    provinces_to character varying(255),
    districts_to character varying(255),
    wards_to character varying(255),
    provinces_code_to character varying(255),
    districts_code_to character varying(255),
    wards_code_to character varying(255),
    provinces_from character varying(255),
    districts_from character varying(255),
    wards_from character varying(255),
    provinces_code_from character varying(255),
    districts_code_from character varying(255),
    wards_code_from character varying(255),
    available boolean DEFAULT true NOT NULL,
    truck_status character varying(255) DEFAULT 'available'::character varying,
    vehicle_type_id bigint
);


ALTER TABLE public.truck_car OWNER TO root;

--
-- Name: truck_car_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.truck_car_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.truck_car_id_seq OWNER TO root;

--
-- Name: truck_car_id_seq1; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.truck_car_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.truck_car_id_seq1 OWNER TO root;

--
-- Name: truck_car_id_seq1; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.truck_car_id_seq1 OWNED BY public.truck_car.id;


--
-- Name: truck_components; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.truck_components (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    purchase_date bigint NOT NULL,
    component_name character varying(100) NOT NULL,
    component_type character varying(50) NOT NULL,
    component_cost numeric(10,2) NOT NULL,
    component_quantity bigint NOT NULL,
    warehouse_address character varying(255),
    component_status character varying(20) DEFAULT 'receive'::character varying NOT NULL,
    note text,
    manager_id bigint NOT NULL,
    vat character varying(20)
);


ALTER TABLE public.truck_components OWNER TO root;

--
-- Name: truck_components_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.truck_components_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.truck_components_id_seq OWNER TO root;

--
-- Name: truck_components_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.truck_components_id_seq OWNED BY public.truck_components.id;


--
-- Name: user; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public."user" (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    user_name character varying(255) NOT NULL,
    password_hash character varying(255) NOT NULL,
    email character varying(255) NOT NULL,
    full_name character varying(255) NOT NULL,
    phone_number character varying(255) NOT NULL,
    day_of_birth character varying(255) NOT NULL,
    citizen_identity_card character varying(255) NOT NULL,
    date_of_citizen_card character varying(255) NOT NULL,
    place_of_citizen_card character varying(255) NOT NULL,
    address character varying(255) NOT NULL,
    company_id bigint
);


ALTER TABLE public."user" OWNER TO root;

--
-- Name: user_department; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.user_department (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    user_id bigint NOT NULL,
    department_id bigint NOT NULL,
    company_id bigint NOT NULL
);


ALTER TABLE public.user_department OWNER TO root;

--
-- Name: user_department_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.user_department_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.user_department_id_seq OWNER TO root;

--
-- Name: user_department_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.user_department_id_seq OWNED BY public.user_department.id;


--
-- Name: user_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.user_id_seq OWNER TO root;

--
-- Name: user_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.user_id_seq OWNED BY public."user".id;


--
-- Name: user_role; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.user_role (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    user_id bigint NOT NULL,
    role_id bigint NOT NULL,
    company_id bigint NOT NULL
);


ALTER TABLE public.user_role OWNER TO root;

--
-- Name: user_role_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.user_role_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.user_role_id_seq OWNER TO root;

--
-- Name: user_role_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.user_role_id_seq OWNED BY public.user_role.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    user_name text,
    email text,
    first_name text,
    last_name text,
    status bigint DEFAULT 0,
    hash_password text,
    role text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone
);


ALTER TABLE public.users OWNER TO root;

--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.users_id_seq OWNER TO root;

--
-- Name: users_id_seq1; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.users_id_seq1
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.users_id_seq1 OWNER TO root;

--
-- Name: users_id_seq1; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.users_id_seq1 OWNED BY public.users.id;


--
-- Name: variables; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.variables (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    owner_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    code character varying(10) NOT NULL
);


ALTER TABLE public.variables OWNER TO root;

--
-- Name: variables_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.variables_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.variables_id_seq OWNER TO root;

--
-- Name: variables_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.variables_id_seq OWNED BY public.variables.id;


--
-- Name: vehicle_types; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.vehicle_types (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    type_name character varying(250) NOT NULL,
    description text
);


ALTER TABLE public.vehicle_types OWNER TO root;

--
-- Name: vehicle_types_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.vehicle_types_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.vehicle_types_id_seq OWNER TO root;

--
-- Name: vehicle_types_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.vehicle_types_id_seq OWNED BY public.vehicle_types.id;


--
-- Name: vehicles; Type: TABLE; Schema: public; Owner: root
--

CREATE TABLE public.vehicles (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    deleted_at timestamp with time zone,
    owner_id bigint NOT NULL,
    description text,
    load numeric(10,2) NOT NULL,
    vehicle_type_id bigint NOT NULL,
    vehicle_status character varying(100) DEFAULT 'unavailable'::character varying NOT NULL,
    vehicle_plate character varying(50) NOT NULL,
    additional_plate character varying(50)
);


ALTER TABLE public.vehicles OWNER TO root;

--
-- Name: vehicles_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.vehicles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.vehicles_id_seq OWNER TO root;

--
-- Name: vehicles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: root
--

ALTER SEQUENCE public.vehicles_id_seq OWNED BY public.vehicles.id;


--
-- Name: warehouses_id_seq; Type: SEQUENCE; Schema: public; Owner: root
--

CREATE SEQUENCE public.warehouses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.warehouses_id_seq OWNER TO root;

--
-- Name: assigned_to id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.assigned_to ALTER COLUMN id SET DEFAULT nextval('public.assigned_to_id_seq'::regclass);


--
-- Name: cancellation_drivers id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.cancellation_drivers ALTER COLUMN id SET DEFAULT nextval('public.cancellation_drivers_id_seq'::regclass);


--
-- Name: company id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.company ALTER COLUMN id SET DEFAULT nextval('public.company_id_seq'::regclass);


--
-- Name: customer_address id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.customer_address ALTER COLUMN id SET DEFAULT nextval('public.customer_address_id_seq'::regclass);


--
-- Name: customer_products id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.customer_products ALTER COLUMN id SET DEFAULT nextval('public.customer_products_id_seq'::regclass);


--
-- Name: customer_routes id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.customer_routes ALTER COLUMN id SET DEFAULT nextval('public.customer_routes_id_seq'::regclass);


--
-- Name: customers id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.customers ALTER COLUMN id SET DEFAULT nextval('public.customers_id_seq'::regclass);


--
-- Name: department id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.department ALTER COLUMN id SET DEFAULT nextval('public.department_id_seq'::regclass);


--
-- Name: drivers id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.drivers ALTER COLUMN id SET DEFAULT nextval('public.drivers_id_seq'::regclass);


--
-- Name: driving_car id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.driving_car ALTER COLUMN id SET DEFAULT nextval('public.driving_car_id_seq'::regclass);


--
-- Name: formulas id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.formulas ALTER COLUMN id SET DEFAULT nextval('public.formulas_id_seq'::regclass);


--
-- Name: internal_customer id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_customer ALTER COLUMN id SET DEFAULT nextval('public.internal_customer_id_seq'::regclass);


--
-- Name: internal_customer_address id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_customer_address ALTER COLUMN id SET DEFAULT nextval('public.internal_customer_address_id_seq'::regclass);


--
-- Name: internal_customer_good_type id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_customer_good_type ALTER COLUMN id SET DEFAULT nextval('public.internal_customer_good_type_id_seq'::regclass);


--
-- Name: internal_good_type id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_good_type ALTER COLUMN id SET DEFAULT nextval('public.internal_good_type_id_seq'::regclass);


--
-- Name: internal_order_media id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_order_media ALTER COLUMN id SET DEFAULT nextval('public.internal_order_media_id_seq'::regclass);


--
-- Name: internal_orders id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_orders ALTER COLUMN id SET DEFAULT nextval('public.internal_orders_id_seq'::regclass);


--
-- Name: internal_warehouse id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_warehouse ALTER COLUMN id SET DEFAULT nextval('public.internal_warehouse_id_seq'::regclass);


--
-- Name: internal_warehouse_good_type id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_warehouse_good_type ALTER COLUMN id SET DEFAULT nextval('public.internal_warehouse_good_type_id_seq'::regclass);


--
-- Name: managers id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.managers ALTER COLUMN id SET DEFAULT nextval('public.managers_id_seq'::regclass);


--
-- Name: media id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.media ALTER COLUMN id SET DEFAULT nextval('public.media_id_seq'::regclass);


--
-- Name: object_images id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.object_images ALTER COLUMN id SET DEFAULT nextval('public.object_images_id_seq'::regclass);


--
-- Name: operators id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.operators ALTER COLUMN id SET DEFAULT nextval('public.operators_id_seq'::regclass);


--
-- Name: order_customer id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.order_customer ALTER COLUMN id SET DEFAULT nextval('public.order_customer_id_seq1'::regclass);


--
-- Name: orders id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.orders ALTER COLUMN id SET DEFAULT nextval('public.orders_id_seq'::regclass);


--
-- Name: owner_car id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.owner_car ALTER COLUMN id SET DEFAULT nextval('public.owner_car_id_seq1'::regclass);


--
-- Name: permission id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.permission ALTER COLUMN id SET DEFAULT nextval('public.permission_id_seq'::regclass);


--
-- Name: products id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.products ALTER COLUMN id SET DEFAULT nextval('public.products_id_seq'::regclass);


--
-- Name: ratings id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.ratings ALTER COLUMN id SET DEFAULT nextval('public.ratings_id_seq'::regclass);


--
-- Name: role id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.role ALTER COLUMN id SET DEFAULT nextval('public.role_id_seq'::regclass);


--
-- Name: role_departments id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.role_departments ALTER COLUMN id SET DEFAULT nextval('public.role_departments_id_seq'::regclass);


--
-- Name: role_hierarchies id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.role_hierarchies ALTER COLUMN id SET DEFAULT nextval('public.role_hierarchies_id_seq'::regclass);


--
-- Name: role_permission id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.role_permission ALTER COLUMN id SET DEFAULT nextval('public.role_permission_id_seq'::regclass);


--
-- Name: task id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.task ALTER COLUMN id SET DEFAULT nextval('public.task_id_seq'::regclass);


--
-- Name: task_process id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.task_process ALTER COLUMN id SET DEFAULT nextval('public.task_process_id_seq'::regclass);


--
-- Name: transactions id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.transactions ALTER COLUMN id SET DEFAULT nextval('public.transactions_id_seq'::regclass);


--
-- Name: truck_car id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.truck_car ALTER COLUMN id SET DEFAULT nextval('public.truck_car_id_seq1'::regclass);


--
-- Name: truck_components id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.truck_components ALTER COLUMN id SET DEFAULT nextval('public.truck_components_id_seq'::regclass);


--
-- Name: user id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public."user" ALTER COLUMN id SET DEFAULT nextval('public.user_id_seq'::regclass);


--
-- Name: user_department id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.user_department ALTER COLUMN id SET DEFAULT nextval('public.user_department_id_seq'::regclass);


--
-- Name: user_role id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.user_role ALTER COLUMN id SET DEFAULT nextval('public.user_role_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq1'::regclass);


--
-- Name: variables id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.variables ALTER COLUMN id SET DEFAULT nextval('public.variables_id_seq'::regclass);


--
-- Name: vehicle_types id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.vehicle_types ALTER COLUMN id SET DEFAULT nextval('public.vehicle_types_id_seq'::regclass);


--
-- Name: vehicles id; Type: DEFAULT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.vehicles ALTER COLUMN id SET DEFAULT nextval('public.vehicles_id_seq'::regclass);


--
-- Data for Name: assigned_to; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.assigned_to (id, created_at, updated_at, deleted_at, task_id, user_id, status, description, date_assigned, deadline, company_id) FROM stdin;
\.


--
-- Data for Name: cancellation_drivers; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.cancellation_drivers (truck_id, pre_order_id, deleted_at, id, created_at, updated_at) FROM stdin;
1	a9513d8c-fe03-11ee-89bb-00ff4e3cbed7	\N	1	2024-05-21 06:10:33.414813+00	2024-05-21 06:10:33.414813+00
2	a9513d8c-fe03-11ee-89bb-00ff4e3cbed7	\N	2	2024-05-21 06:22:12.25193+00	2024-05-21 06:22:12.25193+00
1	bảng lương tài xế 1	\N	1	2024-07-23 04:05:32.863069+00	2024-07-23 04:41:36.293927+00
3	3	\N	1	2024-07-08 03:52:08.035847+00	2024-07-08 03:52:08.035847+00
3	5	\N	2	2024-07-08 03:52:08.035847+00	2024-07-08 03:52:08.035847+00
3	3	\N	3	2024-07-08 04:56:50.448632+00	2024-07-08 04:56:50.448632+00
3	3	\N	4	2024-07-08 06:26:56.855428+00	2024-07-08 06:26:56.855428+00
3	3	\N	5	2024-07-08 06:29:35.078966+00	2024-07-08 06:29:35.078966+00
1	1	\N	1	2024-06-30 11:55:34.483403+00	2024-06-30 11:55:34.483403+00
2	1	\N	2	2024-06-30 11:55:47.294265+00	2024-06-30 11:55:47.294265+00
3	3	\N	3	2024-06-30 11:56:27.422843+00	2024-06-30 11:56:27.422843+00
4	2	\N	4	2024-06-30 11:56:50.687775+00	2024-06-30 11:56:50.687775+00
5	3	\N	5	2024-06-30 11:57:12.536549+00	2024-06-30 11:57:12.536549+00
6	2	\N	6	2024-06-30 11:57:27.931312+00	2024-06-30 11:57:27.931312+00
7	3	\N	7	2024-06-30 11:57:54.294107+00	2024-06-30 11:57:54.294107+00
8	2	\N	8	2024-06-30 11:58:05.310838+00	2024-06-30 11:58:05.310838+00
9	5	\N	9	2024-06-30 11:58:32.251384+00	2024-06-30 11:58:32.251384+00
19	3	2024-07-02 02:35:06.396055+00	11	2024-07-01 08:57:03.073973+00	2024-07-01 08:57:03.073973+00
18	3	2024-07-05 04:46:04.930416+00	10	2024-07-01 08:49:55.228322+00	2024-07-01 08:49:55.228322+00
20	3	\N	14	2024-07-05 04:59:32.366344+00	2024-07-05 04:59:32.366344+00
21	3	\N	15	2024-07-05 05:06:00.162603+00	2024-07-05 05:06:00.162603+00
22	3	\N	16	2024-07-05 05:06:33.969132+00	2024-07-05 05:06:33.969132+00
12	3	\N	17	2024-07-08 03:42:26.671327+00	2024-07-08 03:42:26.671327+00
25	3	\N	20	2024-07-08 06:29:35.075455+00	2024-07-08 06:29:35.075455+00
1	549-816-3218	\N	1	2024-07-15 09:30:38.573185+00	2024-07-15 09:30:38.573185+00
5	xe bồn	\N	4	2024-04-11 09:58:51.502356+00	2024-04-20 19:48:16.095607+00
5	xe bồn	\N	2	2024-04-12 10:12:13.501421+00	2024-04-20 02:51:24.839346+00
5	xe bồn	\N	1	2024-04-12 10:12:13.496877+00	2024-04-20 02:51:24.738988+00
5	xe bồn	\N	6	2024-04-11 09:58:51.502356+00	2024-04-15 23:52:17.41956+00
5	xe bồn	\N	8	2024-04-11 09:58:51.502356+00	2024-04-21 13:41:46.891858+00
5	xe bồn	\N	5	2024-04-11 09:58:51.502356+00	2024-04-21 13:41:46.888871+00
5	xe bồn	\N	3	2024-04-11 09:58:51.502356+00	2024-04-21 13:41:46.891858+00
5	xe bồn	\N	7	2024-04-11 09:58:51.502356+00	2024-07-19 07:08:50.141258+00
5	xe bồn	\N	9	2024-07-19 10:11:44.590186+00	2024-07-19 10:11:44.590186+00
1712308366682	ten linh kien	\N	2	2024-05-30 02:51:16.891085+00	2024-05-30 02:51:16.891085+00
1712308366682	ten linh kien 2	\N	4	2024-05-29 10:16:35.674749+00	2024-05-30 06:18:08.161105+00
1715495960000	ten linh kien 2	\N	3	2024-05-29 10:16:35.674749+00	2024-05-30 06:18:08.161105+00
1715236760000	ten linh kien update	\N	1	2024-05-29 10:16:35.674749+00	2024-05-30 06:18:08.161105+00
1	1	\N	1	2024-06-07 08:47:44.074314+00	2024-06-07 08:47:44.074314+00
2	2	\N	2	2024-06-07 08:51:48.742286+00	2024-06-07 08:51:48.742286+00
5	8	\N	5	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
6	8	\N	6	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
7	3	\N	7	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
9	7	\N	9	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
10	9	\N	10	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
11	13	\N	11	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
12	9999	\N	12	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
119	13	\N	13	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
120	13	\N	14	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
121	13	\N	15	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
4	6	\N	4	2024-06-11 01:59:53.302258+00	2024-06-11 01:59:53.302258+00
3	3	\N	3	2024-06-12 08:51:46.564174+00	2024-06-12 08:51:46.564174+00
8	7	\N	8	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
123	1	\N	16	2024-06-20 09:22:11.72266+00	2024-06-20 09:22:11.72266+00
128	1	\N	17	2024-06-20 09:54:41.286952+00	2024-06-20 09:54:41.286952+00
129	1	\N	18	2024-06-20 09:56:49.43323+00	2024-06-20 09:56:49.43323+00
130	1	\N	19	2024-06-20 09:56:55.267961+00	2024-06-20 09:56:55.267961+00
131	1	\N	20	2024-06-20 09:57:04.01418+00	2024-06-20 09:57:04.01418+00
132	1	\N	21	2024-06-21 03:48:40.329964+00	2024-06-21 03:48:40.329964+00
137	13	\N	24	2024-06-25 23:04:43.967721+00	2024-06-25 23:04:43.967721+00
1	1	\N	1	2024-06-07 06:53:56.066977+00	2024-06-07 06:53:56.066977+00
1	2	\N	2	2024-06-07 06:54:17.800877+00	2024-06-07 06:54:17.800877+00
1	3	\N	3	2024-06-07 06:54:17.800877+00	2024-06-07 06:54:17.800877+00
2	1	\N	4	2024-06-07 06:55:12.134817+00	2024-06-07 06:55:12.134817+00
2	2	\N	5	2024-06-07 06:55:12.134817+00	2024-06-07 06:55:12.134817+00
2	3	\N	6	2024-06-07 06:55:12.134817+00	2024-06-07 06:55:12.134817+00
3	1	\N	7	2024-06-07 06:56:21.302579+00	2024-06-07 06:56:21.302579+00
3	2	\N	8	2024-06-07 06:56:21.302579+00	2024-06-07 06:56:21.302579+00
3	3	\N	9	2024-06-07 06:56:21.302579+00	2024-06-07 06:56:21.302579+00
4	1	\N	10	2024-06-07 06:56:57.981073+00	2024-06-07 06:56:57.981073+00
4	2	\N	11	2024-06-07 06:56:57.981073+00	2024-06-07 06:56:57.981073+00
4	3	\N	12	2024-06-07 06:56:57.981073+00	2024-06-07 06:56:57.981073+00
5	1	\N	15	2024-06-07 07:01:13.311715+00	2024-06-07 07:01:13.311715+00
5	2	\N	16	2024-06-07 07:01:13.311715+00	2024-06-07 07:01:13.311715+00
5	3	\N	17	2024-06-07 07:01:13.311715+00	2024-06-07 07:01:13.311715+00
6	1	\N	18	2024-06-07 07:01:28.012262+00	2024-06-07 07:01:28.012262+00
6	2	\N	19	2024-06-07 07:01:28.012262+00	2024-06-07 07:01:28.012262+00
6	3	\N	20	2024-06-07 07:01:28.012262+00	2024-06-07 07:01:28.012262+00
7	2	\N	21	2024-06-07 07:01:51.908598+00	2024-06-07 07:01:51.908598+00
8	2	\N	22	2024-06-07 07:01:51.908598+00	2024-06-07 07:01:51.908598+00
5	2	\N	23	2024-06-11 01:59:02.849264+00	2024-06-11 01:59:02.849264+00
5	BaoA	\N	5	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00
5	Nguyen Van C	\N	3	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00
5	Nguyen Van A	\N	1	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00
5	BaoC	\N	7	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00
5	Bao	\N	4	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00
5	Nguyen Van E	\N	46	2024-05-14 06:55:02.712044+00	2024-05-14 06:55:02.712044+00
5	BaoB	\N	6	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00
5	Roderick Stiedemann I	2024-07-21 09:09:46.421477+00	70	2024-07-21 02:56:16.613941+00	2024-07-21 09:09:46.416473+00
5	Miss Lynda Ratke	\N	72	2024-07-21 09:09:53.962634+00	2024-07-21 09:14:55.840234+00
\N	AE3WHV9V5NXP	\N	5	2024-07-15 10:19:28.989599+00	2024-07-15 10:19:28.989599+00
\N	EPZT9LKQBCJ0	\N	7	2024-07-15 10:21:12.305213+00	2024-07-15 10:21:12.305213+00
7	AEEL7B1FQWK2	\N	8	2024-07-16 04:57:17.834806+00	2024-07-19 07:08:50.144712+00
\N	W73ZRMESLWHC	\N	9	2024-07-19 06:26:29.477552+00	2024-07-19 06:26:29.477552+00
\N	K5Z0V18VNVLP	\N	10	2024-07-19 06:27:57.700902+00	2024-07-19 06:27:57.700902+00
\N	2CDWU7WH37IL	\N	11	2024-07-19 06:29:18.645836+00	2024-07-19 06:29:18.645836+00
\N	OOXCQB1G0PH7	\N	6	2024-07-15 10:20:38.593326+00	2024-07-15 10:20:38.593326+00
\N	W422FRANEYO2	\N	12	2024-07-19 06:30:27.780707+00	2024-07-19 06:30:27.780707+00
\N	3265DIGFMANB	\N	13	2024-07-19 06:35:11.499136+00	2024-07-19 06:35:11.499136+00
\N	NO0UUF3YF1UR	\N	14	2024-07-19 06:35:42.064686+00	2024-07-19 06:35:42.064686+00
\N	RUD6VRFI4J91	\N	15	2024-07-19 06:35:54.650787+00	2024-07-19 06:35:54.650787+00
\N	SP0V8JIEIUO7	\N	16	2024-07-19 06:37:30.546645+00	2024-07-19 06:37:30.546645+00
\N	Z1MFYBC3ABZX	\N	17	2024-07-19 06:39:33.485189+00	2024-07-19 06:39:33.485189+00
\N	DFSD9WGJV4I2	\N	18	2024-07-19 06:40:14.248003+00	2024-07-19 06:40:14.248003+00
\N	INCZKNV6W9BK	\N	19	2024-07-19 06:40:41.446714+00	2024-07-19 06:40:41.446714+00
7	P3SPPK9TYO11	\N	20	2024-07-19 06:44:04.008822+00	2024-07-19 06:49:26.833266+00
\N	E5VQYSLHRJB4	\N	4	2024-07-15 10:16:20.501495+00	2024-07-15 10:16:20.501495+00
\N	42a2c708-18b3-11ef-b938-00ff4e3cbed7	\N	3	2024-05-02 09:15:37.97492+00	2024-05-17 10:25:49.849392+00
1	235d62f6-0863-11ef-b7c1-00ff4e3cbed7	\N	1	2024-05-02 09:15:37.97492+00	2024-05-02 09:15:37.97492+00
1	a9513d8c-fe03-11ee-89bb-00ff4e3cbed7	\N	2	2024-05-02 09:15:37.97492+00	2024-05-17 10:25:49.849392+00
11	5	\N	1	2024-07-19 06:29:18.651078+00	2024-07-19 06:29:18.651078+00
13	5	\N	3	2024-07-19 06:35:11.502729+00	2024-07-19 06:35:11.502729+00
14	5	\N	4	2024-07-19 06:35:42.071821+00	2024-07-19 06:35:42.071821+00
15	5	\N	5	2024-07-19 06:35:54.657412+00	2024-07-19 06:35:54.657412+00
16	5	\N	6	2024-07-19 06:37:30.556152+00	2024-07-19 06:37:30.556152+00
17	5	\N	7	2024-07-19 06:40:05.855885+00	2024-07-19 06:40:05.855885+00
18	5	\N	8	2024-07-19 06:40:24.326344+00	2024-07-19 06:40:24.326344+00
19	5	\N	9	2024-07-19 06:40:44.194647+00	2024-07-19 06:40:44.194647+00
20	5	\N	10	2024-07-19 06:44:04.016887+00	2024-07-19 06:44:04.016887+00
1	0	\N	2	2024-07-17 01:40:21.263012+00	2024-07-17 01:40:21.263012+00
1	10	\N	3	2024-07-17 01:40:31.878219+00	2024-07-17 01:40:31.878219+00
11	10	\N	7	2024-07-17 02:02:04.133631+00	2024-07-17 02:02:04.133631+00
1	200	\N	1	2024-07-17 01:39:59.508854+00	2024-07-17 02:03:49.303599+00
1	a9513d8c-fe03-11ee-89bb-00ff4e3cbed7	\N	1	2024-05-21 06:10:33.414813+00	2024-05-21 06:10:33.414813+00
2	a9513d8c-fe03-11ee-89bb-00ff4e3cbed7	\N	2	2024-05-21 06:22:12.25193+00	2024-05-21 06:22:12.25193+00
1	bảng lương tài xế 1	\N	1	2024-07-23 04:05:32.863069+00	2024-07-23 04:41:36.293927+00
3	3	\N	1	2024-07-08 03:52:08.035847+00	2024-07-08 03:52:08.035847+00
3	5	\N	2	2024-07-08 03:52:08.035847+00	2024-07-08 03:52:08.035847+00
3	3	\N	3	2024-07-08 04:56:50.448632+00	2024-07-08 04:56:50.448632+00
3	3	\N	4	2024-07-08 06:26:56.855428+00	2024-07-08 06:26:56.855428+00
3	3	\N	5	2024-07-08 06:29:35.078966+00	2024-07-08 06:29:35.078966+00
1	1	\N	1	2024-06-30 11:55:34.483403+00	2024-06-30 11:55:34.483403+00
2	1	\N	2	2024-06-30 11:55:47.294265+00	2024-06-30 11:55:47.294265+00
3	3	\N	3	2024-06-30 11:56:27.422843+00	2024-06-30 11:56:27.422843+00
4	2	\N	4	2024-06-30 11:56:50.687775+00	2024-06-30 11:56:50.687775+00
5	3	\N	5	2024-06-30 11:57:12.536549+00	2024-06-30 11:57:12.536549+00
6	2	\N	6	2024-06-30 11:57:27.931312+00	2024-06-30 11:57:27.931312+00
7	3	\N	7	2024-06-30 11:57:54.294107+00	2024-06-30 11:57:54.294107+00
8	2	\N	8	2024-06-30 11:58:05.310838+00	2024-06-30 11:58:05.310838+00
9	5	\N	9	2024-06-30 11:58:32.251384+00	2024-06-30 11:58:32.251384+00
19	3	2024-07-02 02:35:06.396055+00	11	2024-07-01 08:57:03.073973+00	2024-07-01 08:57:03.073973+00
18	3	2024-07-05 04:46:04.930416+00	10	2024-07-01 08:49:55.228322+00	2024-07-01 08:49:55.228322+00
20	3	\N	14	2024-07-05 04:59:32.366344+00	2024-07-05 04:59:32.366344+00
21	3	\N	15	2024-07-05 05:06:00.162603+00	2024-07-05 05:06:00.162603+00
22	3	\N	16	2024-07-05 05:06:33.969132+00	2024-07-05 05:06:33.969132+00
12	3	\N	17	2024-07-08 03:42:26.671327+00	2024-07-08 03:42:26.671327+00
25	3	\N	20	2024-07-08 06:29:35.075455+00	2024-07-08 06:29:35.075455+00
1	549-816-3218	\N	1	2024-07-15 09:30:38.573185+00	2024-07-15 09:30:38.573185+00
5	xe bồn	\N	4	2024-04-11 09:58:51.502356+00	2024-04-20 19:48:16.095607+00
5	xe bồn	\N	2	2024-04-12 10:12:13.501421+00	2024-04-20 02:51:24.839346+00
5	xe bồn	\N	1	2024-04-12 10:12:13.496877+00	2024-04-20 02:51:24.738988+00
5	xe bồn	\N	6	2024-04-11 09:58:51.502356+00	2024-04-15 23:52:17.41956+00
5	xe bồn	\N	8	2024-04-11 09:58:51.502356+00	2024-04-21 13:41:46.891858+00
5	xe bồn	\N	5	2024-04-11 09:58:51.502356+00	2024-04-21 13:41:46.888871+00
5	xe bồn	\N	3	2024-04-11 09:58:51.502356+00	2024-04-21 13:41:46.891858+00
5	xe bồn	\N	7	2024-04-11 09:58:51.502356+00	2024-07-19 07:08:50.141258+00
5	xe bồn	\N	9	2024-07-19 10:11:44.590186+00	2024-07-19 10:11:44.590186+00
1712308366682	ten linh kien	\N	2	2024-05-30 02:51:16.891085+00	2024-05-30 02:51:16.891085+00
1712308366682	ten linh kien 2	\N	4	2024-05-29 10:16:35.674749+00	2024-05-30 06:18:08.161105+00
1715495960000	ten linh kien 2	\N	3	2024-05-29 10:16:35.674749+00	2024-05-30 06:18:08.161105+00
1715236760000	ten linh kien update	\N	1	2024-05-29 10:16:35.674749+00	2024-05-30 06:18:08.161105+00
1	1	\N	1	2024-06-07 08:47:44.074314+00	2024-06-07 08:47:44.074314+00
2	2	\N	2	2024-06-07 08:51:48.742286+00	2024-06-07 08:51:48.742286+00
5	8	\N	5	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
6	8	\N	6	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
7	3	\N	7	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
9	7	\N	9	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
10	9	\N	10	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
11	13	\N	11	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
12	9999	\N	12	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
119	13	\N	13	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
120	13	\N	14	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
121	13	\N	15	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
4	6	\N	4	2024-06-11 01:59:53.302258+00	2024-06-11 01:59:53.302258+00
3	3	\N	3	2024-06-12 08:51:46.564174+00	2024-06-12 08:51:46.564174+00
8	7	\N	8	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00
123	1	\N	16	2024-06-20 09:22:11.72266+00	2024-06-20 09:22:11.72266+00
128	1	\N	17	2024-06-20 09:54:41.286952+00	2024-06-20 09:54:41.286952+00
129	1	\N	18	2024-06-20 09:56:49.43323+00	2024-06-20 09:56:49.43323+00
130	1	\N	19	2024-06-20 09:56:55.267961+00	2024-06-20 09:56:55.267961+00
131	1	\N	20	2024-06-20 09:57:04.01418+00	2024-06-20 09:57:04.01418+00
132	1	\N	21	2024-06-21 03:48:40.329964+00	2024-06-21 03:48:40.329964+00
137	13	\N	24	2024-06-25 23:04:43.967721+00	2024-06-25 23:04:43.967721+00
1	1	\N	1	2024-06-07 06:53:56.066977+00	2024-06-07 06:53:56.066977+00
1	2	\N	2	2024-06-07 06:54:17.800877+00	2024-06-07 06:54:17.800877+00
1	3	\N	3	2024-06-07 06:54:17.800877+00	2024-06-07 06:54:17.800877+00
2	1	\N	4	2024-06-07 06:55:12.134817+00	2024-06-07 06:55:12.134817+00
2	2	\N	5	2024-06-07 06:55:12.134817+00	2024-06-07 06:55:12.134817+00
2	3	\N	6	2024-06-07 06:55:12.134817+00	2024-06-07 06:55:12.134817+00
3	1	\N	7	2024-06-07 06:56:21.302579+00	2024-06-07 06:56:21.302579+00
3	2	\N	8	2024-06-07 06:56:21.302579+00	2024-06-07 06:56:21.302579+00
3	3	\N	9	2024-06-07 06:56:21.302579+00	2024-06-07 06:56:21.302579+00
4	1	\N	10	2024-06-07 06:56:57.981073+00	2024-06-07 06:56:57.981073+00
4	2	\N	11	2024-06-07 06:56:57.981073+00	2024-06-07 06:56:57.981073+00
4	3	\N	12	2024-06-07 06:56:57.981073+00	2024-06-07 06:56:57.981073+00
5	1	\N	15	2024-06-07 07:01:13.311715+00	2024-06-07 07:01:13.311715+00
5	2	\N	16	2024-06-07 07:01:13.311715+00	2024-06-07 07:01:13.311715+00
5	3	\N	17	2024-06-07 07:01:13.311715+00	2024-06-07 07:01:13.311715+00
6	1	\N	18	2024-06-07 07:01:28.012262+00	2024-06-07 07:01:28.012262+00
6	2	\N	19	2024-06-07 07:01:28.012262+00	2024-06-07 07:01:28.012262+00
6	3	\N	20	2024-06-07 07:01:28.012262+00	2024-06-07 07:01:28.012262+00
7	2	\N	21	2024-06-07 07:01:51.908598+00	2024-06-07 07:01:51.908598+00
8	2	\N	22	2024-06-07 07:01:51.908598+00	2024-06-07 07:01:51.908598+00
5	2	\N	23	2024-06-11 01:59:02.849264+00	2024-06-11 01:59:02.849264+00
5	BaoA	\N	5	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00
5	Nguyen Van C	\N	3	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00
5	Nguyen Van A	\N	1	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00
5	BaoC	\N	7	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00
5	Bao	\N	4	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00
5	Nguyen Van E	\N	46	2024-05-14 06:55:02.712044+00	2024-05-14 06:55:02.712044+00
5	BaoB	\N	6	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00
5	Roderick Stiedemann I	2024-07-21 09:09:46.421477+00	70	2024-07-21 02:56:16.613941+00	2024-07-21 09:09:46.416473+00
5	Miss Lynda Ratke	\N	72	2024-07-21 09:09:53.962634+00	2024-07-21 09:14:55.840234+00
\N	AE3WHV9V5NXP	\N	5	2024-07-15 10:19:28.989599+00	2024-07-15 10:19:28.989599+00
\N	EPZT9LKQBCJ0	\N	7	2024-07-15 10:21:12.305213+00	2024-07-15 10:21:12.305213+00
7	AEEL7B1FQWK2	\N	8	2024-07-16 04:57:17.834806+00	2024-07-19 07:08:50.144712+00
\N	W73ZRMESLWHC	\N	9	2024-07-19 06:26:29.477552+00	2024-07-19 06:26:29.477552+00
\N	K5Z0V18VNVLP	\N	10	2024-07-19 06:27:57.700902+00	2024-07-19 06:27:57.700902+00
\N	2CDWU7WH37IL	\N	11	2024-07-19 06:29:18.645836+00	2024-07-19 06:29:18.645836+00
\N	OOXCQB1G0PH7	\N	6	2024-07-15 10:20:38.593326+00	2024-07-15 10:20:38.593326+00
\N	W422FRANEYO2	\N	12	2024-07-19 06:30:27.780707+00	2024-07-19 06:30:27.780707+00
\N	3265DIGFMANB	\N	13	2024-07-19 06:35:11.499136+00	2024-07-19 06:35:11.499136+00
\N	NO0UUF3YF1UR	\N	14	2024-07-19 06:35:42.064686+00	2024-07-19 06:35:42.064686+00
\N	RUD6VRFI4J91	\N	15	2024-07-19 06:35:54.650787+00	2024-07-19 06:35:54.650787+00
\N	SP0V8JIEIUO7	\N	16	2024-07-19 06:37:30.546645+00	2024-07-19 06:37:30.546645+00
\N	Z1MFYBC3ABZX	\N	17	2024-07-19 06:39:33.485189+00	2024-07-19 06:39:33.485189+00
\N	DFSD9WGJV4I2	\N	18	2024-07-19 06:40:14.248003+00	2024-07-19 06:40:14.248003+00
\N	INCZKNV6W9BK	\N	19	2024-07-19 06:40:41.446714+00	2024-07-19 06:40:41.446714+00
7	P3SPPK9TYO11	\N	20	2024-07-19 06:44:04.008822+00	2024-07-19 06:49:26.833266+00
\N	E5VQYSLHRJB4	\N	4	2024-07-15 10:16:20.501495+00	2024-07-15 10:16:20.501495+00
\N	42a2c708-18b3-11ef-b938-00ff4e3cbed7	\N	3	2024-05-02 09:15:37.97492+00	2024-05-17 10:25:49.849392+00
1	235d62f6-0863-11ef-b7c1-00ff4e3cbed7	\N	1	2024-05-02 09:15:37.97492+00	2024-05-02 09:15:37.97492+00
1	a9513d8c-fe03-11ee-89bb-00ff4e3cbed7	\N	2	2024-05-02 09:15:37.97492+00	2024-05-17 10:25:49.849392+00
11	5	\N	1	2024-07-19 06:29:18.651078+00	2024-07-19 06:29:18.651078+00
13	5	\N	3	2024-07-19 06:35:11.502729+00	2024-07-19 06:35:11.502729+00
14	5	\N	4	2024-07-19 06:35:42.071821+00	2024-07-19 06:35:42.071821+00
15	5	\N	5	2024-07-19 06:35:54.657412+00	2024-07-19 06:35:54.657412+00
16	5	\N	6	2024-07-19 06:37:30.556152+00	2024-07-19 06:37:30.556152+00
17	5	\N	7	2024-07-19 06:40:05.855885+00	2024-07-19 06:40:05.855885+00
18	5	\N	8	2024-07-19 06:40:24.326344+00	2024-07-19 06:40:24.326344+00
19	5	\N	9	2024-07-19 06:40:44.194647+00	2024-07-19 06:40:44.194647+00
20	5	\N	10	2024-07-19 06:44:04.016887+00	2024-07-19 06:44:04.016887+00
1	0	\N	2	2024-07-17 01:40:21.263012+00	2024-07-17 01:40:21.263012+00
1	10	\N	3	2024-07-17 01:40:31.878219+00	2024-07-17 01:40:31.878219+00
11	10	\N	7	2024-07-17 02:02:04.133631+00	2024-07-17 02:02:04.133631+00
1	200	\N	1	2024-07-17 01:39:59.508854+00	2024-07-17 02:03:49.303599+00
1	1	\N	1	2024-06-07 07:40:33.825651+00	2024-06-07 07:40:33.825651+00
2	1	\N	2	2024-06-07 07:40:38.936411+00	2024-06-07 07:40:38.936411+00
3	2	\N	3	2024-06-07 07:40:49.889392+00	2024-06-07 07:40:49.889392+00
4	2	\N	4	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00
5	2	\N	5	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00
6	2	\N	6	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00
7	3	\N	7	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00
8	3	\N	8	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00
9	3	\N	9	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00
10	5	\N	10	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00
11	5	\N	11	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00
12	5	\N	12	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00
119	5	\N	13	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00
120	5	\N	14	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00
121	5	\N	15	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00
131	2	\N	16	2024-06-20 09:57:04.023718+00	2024-06-20 09:57:04.023718+00
132	2	\N	17	2024-06-21 03:48:40.33464+00	2024-06-21 03:48:40.33464+00
12	1	\N	18	2024-06-21 06:39:31.593462+00	2024-06-21 06:39:31.593462+00
137	5	\N	19	2024-06-25 23:04:46.654166+00	2024-06-25 23:04:46.654166+00
1	ximang	\N	1	2024-07-12 09:52:24.297249+00	2024-07-12 09:52:24.297249+00
\.


--
-- Data for Name: company; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.company (id, created_at, updated_at, deleted_at, name, description, company_code) FROM stdin;
0	2024-06-21 10:25:59.035219+00	2024-06-21 10:25:59.035219+00	\N	Empty	\N	\N
1	2024-06-07 04:27:54.49016+00	2024-06-07 04:27:54.49016+00	\N	Hoa Kien Nhan	cong ty Hoa Kien Nhan	HKN123
3	2024-06-13 09:19:17.035646+00	2024-06-13 09:19:17.035646+00	\N	Hoa Kien Nhan2	cong ty hoa kien nha	HKN234
\.


--
-- Data for Name: customer_address; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.customer_address (id, created_at, updated_at, deleted_at, customer_id, contact_name, address_phone_number, province, district, ward, detail_address, lat, long, is_default) FROM stdin;
20	2024-10-21 10:01:00.053955+00	2024-11-12 03:26:19.54041+00	\N	3	Lewis Hills	343-568-1683	79	769	26830	65 Đường A, Long Bình, Quận 9, Hồ Chí Minh, Việt Nam	10.890932590869472	106.8283156848659	f
15	2024-10-21 10:00:45.902072+00	2024-11-12 03:26:19.54041+00	\N	3	Abraham Smitham	341-372-6015	79	769	26803	khu phố 4, Tam Bình, Thủ Đức, Hồ Chí Minh, Việt Nam	10.867438933062349	106.73375105479278	f
2	2024-10-17 10:06:21.180483+00	2024-10-21 10:01:32.846743+00	\N	5	Inez Rodriguez	809-500-5856	79	769	26815	982 Đ. Kha Vạn Cân, Linh Chiểu, thành phố Thủ Đức, Hồ Chí Minh 70000, Việt Nam	10.853404046557174	106.75474805769466	f
11	2024-10-21 09:59:26.034621+00	2024-10-21 10:01:32.846743+00	\N	5	Lynne Volkman	500-732-0438	79	769	26842	15 Đ Làng Tăng Phú, Tăng Nhơn Phú A, Quận 9, Hồ Chí Minh, Việt Nam	10.840422627176864	106.79720804571203	f
12	2024-10-21 09:59:27.061928+00	2024-10-21 10:01:32.846743+00	\N	5	Tommy Reichel	739-823-4950	79	769	26827	96 Đ. Số 3, Trường Thọ, Thủ Đức, Hồ Chí Minh, Việt Nam	10.83437278339671	106.75604507660363	f
8	2024-10-21 09:59:18.860293+00	2024-11-12 03:26:19.54041+00	\N	3	Angel Kiehn	216-213-8480	79	769	26818	11/6 Đ. số 5, khu phố 3, Thủ Đức, Hồ Chí Minh 700000, Việt Nam	10.856291486212898	106.75347156918602	f
70	2024-11-15 07:51:55.504562+00	2024-11-15 07:51:55.504562+00	\N	117	Kellie Hackett	357-591-5957	Ms.	Jr.	Dr.	fi	68.3287	-99.2290	t
85	2024-11-15 10:10:14.112419+00	2024-11-15 10:10:14.112419+00	\N	7	gv	08888888	01	002	00040	8888	66.1809	21.9767	f
467	2024-11-19 10:14:28.175245+00	2024-11-19 10:14:28.175245+00	\N	752	nha han 1	0987654567	01	001	0001	haw	-60.9655	169.2644	t
14	2024-10-21 10:00:43.175048+00	2024-11-07 04:45:59.032848+00	\N	2	Cesar Kutch	401-789-4531	79	769	26821	Khách Sạn Vũ Với, 35 Đ. Số 40, Linh Đông, Thủ Đức, Hồ Chí Minh, Việt Nam	10.84805591446394	106.75166852544902	f
5	2024-10-21 09:59:12.631291+00	2024-11-07 04:45:59.032848+00	\N	2	Raymond Friesen	668-228-9427	79	769	26854	1792 Đ. Nguyễn Duy Trinh, Trường Thạnh, Quận 9, Hồ Chí Minh 70000, Việt Nam	10.813595884558357	106.83404429396899	f
6	2024-10-21 09:59:15.445676+00	2024-11-07 04:45:59.032848+00	\N	2	Mrs. Beverly Bednar	302-755-3749	79	769	27112	14 đường 100, Phường Thạnh Mỹ Lợi, Thủ Đức, Hồ Chí Minh 71114, Việt Nam	10.770024727695503	106.76844721043359	f
19	2024-10-21 10:00:56.651921+00	2024-11-07 04:45:59.032848+00	\N	2	Harriet Halvorson	934-904-4429	79	769	26809	8 Đường 17 kp3, Hiệp Bình Phước, Thủ Đức, Hồ Chí Minh, Việt Nam	10.860663433594931	106.72332983256399	f
50	2024-11-07 04:45:59.03566+00	2024-11-07 04:45:59.03566+00	\N	2	nha	0987654345	01	003	00094	16, an duong vuong	66.1809	21.9767	t
54	2024-11-08 06:45:42.21173+00	2024-11-08 06:45:42.21173+00	\N	15	Linh hkn	0897654321	01	002	00040	59, an lac, khach san nam cuong	13.8127	-7.1436	t
468	2024-11-20 06:11:02.697326+00	2024-11-20 06:11:02.697326+00	\N	756	Bảo dt	0869307209	79	764	26887	số 20	10.54272471248186	106.36659365492204	t
55	2024-11-08 06:48:39.792393+00	2024-11-08 06:48:39.792393+00	\N	15	bao hkn	0852369741	01	002	00040	khách sạn vũ đại, đối diện chung cư vin home	164.47005235655612	138.09961426223632	f
469	2024-11-20 06:11:57.182707+00	2024-11-20 06:11:57.182707+00	\N	756	Linh xe ôm	0852314679	04	043	01327	số hàng lán	10.413810134719036	106.66815726734946	f
470	2024-11-20 06:18:45.174397+00	2024-11-20 06:18:45.174397+00	\N	752	han le	0346249582	01	002	00040	ngõ 55	10.334803162783043	106.26370159844573	f
471	2024-11-20 07:09:09.999632+00	2024-11-20 07:09:09.999632+00	\N	757	hân	0986534589	01	005	00160	ngoz 78	10.672107826747656	106.83998376042432	t
21	2024-11-04 16:15:11.711093+00	2024-11-04 16:15:11.711093+00	\N	6	null	22222	01	001	00001	sre	13.8127	-7.1436	t
22	2024-11-04 16:17:11.040478+00	2024-11-04 16:17:11.040478+00	\N	7	ab	12121212	01	001	00001	ab	13.8127	-7.1436	t
9	2024-10-21 09:59:22.008648+00	2024-11-12 03:04:38.621698+00	\N	4	Lorena Franecki	871-226-6837	79	769	26797	111b Ng. Chí Quốc, Bình Chiểu, Thủ Đức, Hồ Chí Minh, Việt Nam	10.87656735809664	106.7261688364827	f
10	2024-10-21 09:59:23.320323+00	2024-11-12 03:04:38.621698+00	\N	4	Darrel Sanford	512-675-9011	79	769	26839	123-125 Lê Văn Việt, P, Quận 9, Hồ Chí Minh 700000, Việt Nam	10.846360611260952	106.77828362793493	f
17	2024-10-21 10:00:51.133549+00	2024-10-21 10:00:51.133549+00	\N	5	Dominic Bashirian	258-353-5881	79	769	26857	336, Long Phước, Quận 9, Hồ Chí Minh, Việt Nam	10.806998351924051	106.85930926867326	t
16	2024-10-21 10:00:48.612559+00	2024-11-12 03:04:38.621698+00	\N	4	Marilyn Mills III	814-278-3148	79	769	26833	309 Nguyễn Văn Tăng, Long Thạnh Mỹ, Quận 9, Hồ Chí Minh, Việt Nam	10.841598146839184	106.8230836173034	f
23	2024-11-05 07:11:45.102806+00	2024-11-05 07:11:45.102806+00	\N	14	Bao A	0987654321	01	001	00001	so 10, an 	13.8127	-7.1436	t
13	2024-10-21 10:00:40.821112+00	2024-11-12 03:26:58.919401+00	\N	1	Fredrick Bechtelar	885-973-4672	79	769	26806	14 Bình Phú, Tam Phú, Thủ Đức, Hồ Chí Minh 700000, Việt Nam	10.85461922755536	106.73908242443039	f
4	2024-10-18 08:45:03.338968+00	2024-11-12 03:26:58.919401+00	\N	1	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	f
3	2024-10-18 08:45:00.483965+00	2024-11-12 03:26:58.919401+00	\N	1	Dr. Sonja Christiansen	664-503-7747	79	769	26812	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	f
472	2024-11-20 07:10:42.011844+00	2024-11-20 07:10:42.011844+00	\N	757	hân	0664865864	44	456	19216	jsjd	10.857193238762989	107.17791282961322	f
473	2024-11-20 07:22:54.120203+00	2024-11-20 07:22:54.120203+00	\N	758	han	0765382563	34	343	13093	jsjs	10.530149811745902	106.57360725930458	t
474	2024-11-20 07:23:41.982694+00	2024-11-20 07:23:41.982694+00	\N	758	hân	06438683965	10	084	02809	znxn	10.518993973654263	107.00131376552662	f
475	2024-11-20 08:22:06.140895+00	2024-11-20 08:22:06.140895+00	\N	756	Khanh	0192019283	02	024	00691	bao	10.935039177697119	106.91360526067567	f
476	2024-11-20 08:26:02.042199+00	2024-11-20 08:26:02.042199+00	\N	759	khánh	0968535468	79	777	27451	hẻm 56	10.84582761051965	107.05831674339302	t
477	2024-11-20 08:27:06.210128+00	2024-11-20 08:27:06.210128+00	\N	759	khánh 4	09668656858	08	072	02221	hẻm 45	11.033250310249406	107.11628593083184	f
478	2024-11-20 08:36:49.461805+00	2024-11-20 08:36:49.461805+00	\N	760	linh	08694685828	06	060	01861	smdnfb	11.066623483668096	107.16087205363938	t
479	2024-11-20 08:38:35.604652+00	2024-11-20 08:38:35.604652+00	\N	760	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	f
480	2024-11-20 08:57:24.107953+00	2024-11-20 08:57:24.107953+00	\N	760	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	f
481	2024-11-20 09:58:39.543467+00	2024-11-20 09:58:39.543467+00	\N	761	hân	0896358685	02	029	00880	hẻm 67	10.582577101881897	107.24205999081703	t
49	2024-11-07 04:43:05.465414+00	2024-11-07 04:45:59.032848+00	\N	2	moi	0987654320	01	001	00001	54, dg	66.1809	21.9767	f
7	2024-10-21 09:59:17.94122+00	2024-11-12 03:26:19.54041+00	\N	3	Mark Zieme	478-884-7008	79	769	26836	153 Đ. Nam Cao, Phường Tân Phú, Thủ Đức, Hồ Chí Minh, Việt Nam	10.856181213947007	106.80284332269044	t
1	2024-10-17 09:55:37.537319+00	2024-11-12 03:04:38.621698+00	\N	4	Joshua Boyer	481-637-4467	79	769	26794	76/4, 76/4 QL1A, Linh Xuân, Thủ Đức, Hồ Chí Minh, Việt Nam	10.882023811191013	106.77507815208371	t
52	2024-11-07 21:28:05.79742+00	2024-11-07 21:28:05.79742+00	\N	6	Cat lai	09876544444	01	001	00001	89 truong luu	66.1809	21.9767	f
53	2024-11-07 21:32:51.04876+00	2024-11-07 21:32:51.04876+00	\N	6	Bien Hoa	0987665432	04	045	01367	12 tt	66.8096324254401	120.47926259712428	f
56	2024-11-12 02:36:08.639492+00	2024-11-12 02:36:08.639492+00	\N	16	0123456789	639-967-2713	0123456788	district 2	an khanh	14, 100 street	-46.3432	151.3428	t
119	2024-11-18 04:58:36.053969+00	2024-11-18 04:58:36.053969+00	\N	347	bao an	0987654432	01	001	00007	so 24	13.8127	-7.1436	t
152	2024-11-18 05:01:04.246186+00	2024-11-18 05:01:04.246186+00	\N	409	bao an	0987654433	01	001	00007	so 24	13.8127	-7.1436	t
185	2024-11-18 05:32:03.868932+00	2024-11-18 05:32:03.868932+00	\N	442	bao ve	09882988222	01	001	00007	bao 24	13.8127	-7.1436	t
218	2024-11-18 07:55:15.91742+00	2024-11-18 07:55:15.91742+00	\N	475	bao na	0987654543	01	002	00040	24 an phu	13.8127	-7.1436	t
251	2024-11-18 07:59:22.236926+00	2024-11-18 07:59:22.236926+00	\N	7	a Linh	0987654342	01	001	00006	2 ba trung	66.1809	21.9767	f
284	2024-11-18 15:00:49.869118+00	2024-11-18 15:00:49.869118+00	\N	7	abc	121212121	02	030	00919	12 dan	66.1809	21.9767	f
285	2024-11-18 15:06:45.966269+00	2024-11-18 15:06:45.966269+00	\N	7	abcd	098765473	02	030	00919	100 so 14	66.1809	21.9767	f
286	2024-11-18 15:07:24.880827+00	2024-11-18 15:07:24.880827+00	\N	7	abcd	12345	02	030	00919	1245 so 34 ta quang	66.1809	21.9767	f
287	2024-11-19 04:28:38.959559+00	2024-11-19 04:28:38.959559+00	\N	580	Hân Lê	0123456789	01	001	00016	55 Hoàng Hoa Thám	13.8127	-7.1436	t
26	2024-11-07 04:40:49.1557+00	2024-11-12 03:26:19.54041+00	\N	3	Bernard Funk DVM	987-623-3058	Mrs.	Jr.	Ms.	ja	66.1809	21.9767	f
42	2024-11-07 04:42:19.990794+00	2024-11-12 03:26:19.54041+00	\N	3	Bernard Funk DVM A	987-623-30581	Mrs.	Jr.	Ms.	ja	66.1809	21.9767	f
46	2024-11-07 04:42:35.727467+00	2024-11-12 03:26:19.54041+00	\N	3	Bernard Funk DVM BA	987-623-3018	Mrs.	Jr.	Ms.	ja	66.1809	21.9767	f
47	2024-11-07 04:42:42.966156+00	2024-11-12 03:26:19.54041+00	\N	3	moi A	09876543211	01	001	00001	54, dg	66.1809	21.9767	f
48	2024-11-07 04:42:50.98969+00	2024-11-12 03:26:19.54041+00	\N	3	moi A	0987654322	01	001	00001	54, dg	66.1809	21.9767	f
59	2024-11-12 03:06:56.471713+00	2024-11-12 03:26:19.54041+00	\N	3	Eduardo Hintz	697-479-0520	Hà Nội	Ba Đình	Cống Vị	Số 10, ngõ 25 Đặng Dung	21.028511	105.854167	f
60	2024-11-15 07:43:58.313586+00	2024-11-15 07:43:58.313586+00	\N	23	Roman Cronin	601-654-9858	Ms.	Sr.	Mrs.	ar	-59.7332	-17.5276	t
61	2024-11-15 07:45:38.744749+00	2024-11-15 07:45:38.744749+00	\N	39	bao A	09876543246	01	001	00001	so 4 hang xam	13.8127	-7.1436	t
62	2024-11-15 07:46:34.719143+00	2024-11-15 07:46:34.719143+00	\N	52	bao AB	09876789876	01	001	00001	so 4 hang xam	13.8127	-7.1436	t
64	2024-11-15 07:47:34.143187+00	2024-11-15 07:47:34.143187+00	\N	75	bao ABC	09876789879	01	001	00001	so 4 hang xam	13.8127	-7.1436	t
66	2024-11-15 07:48:17.616223+00	2024-11-15 07:48:17.616223+00	\N	96	hanle	1234567890	gia lai	an khe	tay son	hai ba trung	0.0645	-88.6996	t
67	2024-11-15 07:48:32.930357+00	2024-11-15 07:48:32.930357+00	\N	100	bao ABCD	09876789870	01	001	00001	so 4 hang xam	13.8127	-7.1436	t
68	2024-11-15 07:50:03.631286+00	2024-11-15 07:50:03.631286+00	\N	112	bao ABCDE	098767898709	01	001	00001	so 4 hang xam	13.8127	-7.1436	t
71	2024-11-15 07:55:55.871608+00	2024-11-15 07:55:55.871608+00	\N	145	bao AABCDE	0987067898709	01	001	00001	so 4 hang xam	13.8127	-7.1436	t
72	2024-11-15 07:57:51.513493+00	2024-11-15 07:57:51.513493+00	\N	146	baoABCDEF	09876789878	01	001	00001	so 4 hang xam	13.8127	-7.1436	t
75	2024-11-15 08:06:29.926734+00	2024-11-15 08:06:29.926734+00	\N	155	Terrance Friesen	0123452	Ms.	DVM	Mr.	it	34.2576	-113.1349	t
76	2024-11-15 08:06:46.890472+00	2024-11-15 08:06:46.890472+00	\N	157	Luz Graham	01234522	Dr.	IV	Mr.	sm	-40.5250	103.7340	t
77	2024-11-15 08:09:58.14174+00	2024-11-15 08:09:58.14174+00	\N	158	Alicia McGlynn	011234522	Mrs.	Jr.	Mrs.	ha	-31.0122	-18.4616	t
78	2024-11-15 08:10:10.618083+00	2024-11-15 08:10:10.618083+00	\N	159	baoABCDEFE	09876789880	01	001	00001	so 4 hang xam	13.8127	-7.1436	t
79	2024-11-15 08:10:57.936514+00	2024-11-15 08:10:57.936514+00	\N	164	baoABCDEFEB	09876789885	01	001	00001	so 4 hang xam	13.8127	-7.1436	t
80	2024-11-15 08:11:48.410993+00	2024-11-15 08:11:48.410993+00	\N	169	Johnnie Schultz	0112314522	Mr.	PhD	Mr.	id	-76.1493	173.4576	t
81	2024-11-15 08:13:12.093432+00	2024-11-15 08:13:12.093432+00	\N	172	baoABCDEFER1	098767898601	01	001	00001	so 4 hang xam	13.8127	-7.1436	t
320	2024-11-19 04:33:27.226056+00	2024-11-19 04:33:27.226056+00	\N	607	Hân	0869321547	01	003	00094	134 an lac	13.8127	-7.1436	t
353	2024-11-19 04:35:09.216949+00	2024-11-19 04:35:09.216949+00	\N	640	bao	0987584732	02	027	00772	so 14	13.8127	-7.1436	t
386	2024-11-19 04:41:55.14819+00	2024-11-19 04:41:55.14819+00	\N	673	Lê Nhã Hân	0369552365	01	001	00001	23 hẻm 55	13.8127	-7.1436	t
419	2024-11-19 04:45:05.84529+00	2024-11-19 04:45:05.84529+00	\N	706	han heo	0852369471	02	026	00715	heo con	13.8127	-7.1436	t
83	2024-11-15 08:16:01.667504+00	2024-11-15 08:16:01.667504+00	\N	175	bao ABCDE	09876781987097	01	001	00001	so 4 hang xam	13.8127	-7.1436	t
452	2024-11-19 06:59:11.878104+00	2024-11-19 06:59:11.878104+00	\N	640	Han	0987654362	02	027	00778	28.mn	19.691929768498895	-94.33867854826099	f
453	2024-11-19 07:00:53.110927+00	2024-11-19 07:00:53.110927+00	\N	640	CDE	0987172653	02	027	00778	1233 an lac	75.40992120072153	-28.441733667395425	f
454	2024-11-19 07:24:49.268705+00	2024-11-19 07:24:49.268705+00	\N	640	Bao A	098765463	02	027	00778	34 an lac	10.597808625303523	106.51728802735788	f
455	2024-11-19 07:25:13.955513+00	2024-11-19 07:25:13.955513+00	\N	640	Bao B	0984736251	02	027	00778	Binh tan 456	10.257381823872283	106.88753744246766	f
456	2024-11-19 07:49:14.126628+00	2024-11-19 07:49:14.126628+00	\N	739	han le	0346249552	01	002	00043	14 ường 100	10.810597849265278	106.97032230916167	t
461	2024-11-19 07:56:08.00651+00	2024-11-19 07:56:08.00651+00	\N	739	han le	0346249553	79	769	26818	54 đường số 2	10.82124242881269	106.4844112161959	f
462	2024-11-19 08:00:42.393969+00	2024-11-19 08:00:42.393969+00	\N	739	han han	0346249532	62	617	23416	nguyễn bỉnh khiêm	10.548956207761467	106.75198987759788	f
463	2024-11-19 08:24:34.326747+00	2024-11-19 08:24:34.326747+00	\N	740	han le	0834692563	01	002	00037	13 dươngd 100	10.756284421745871	106.85798460130704	t
464	2024-11-19 08:28:14.967212+00	2024-11-19 08:28:14.967212+00	\N	740	dt	0897643251	02	024	00688	nsnsjsj	10.774371235468008	106.86845762301319	f
465	2024-11-19 09:57:01.514868+00	2024-11-19 09:57:01.514868+00	\N	741	hân lê 3	0354567846	01	001	0004	56 dupng 100	-15.4403	-26.4388	t
482	2024-11-20 10:01:09.636599+00	2024-11-20 10:01:09.636599+00	\N	761	khánh	0896865865	04	047	01453	hẻm 98	10.78547043271833	107.119539193035	f
483	2024-11-20 10:10:32.512625+00	2024-11-20 10:10:32.512625+00	\N	762	QWQWQW	1212121212	02	026	00715	121212	10.857847402071107	107.09306819159096	t
484	2024-11-21 06:18:29.742658+00	2024-11-21 06:18:29.742658+00	\N	763	hân	0896353866	01	001	00001	bsns	10.883022853969782	106.45823418547165	t
517	2024-11-21 06:20:25.460232+00	2024-11-21 06:20:25.460232+00	\N	763	hân hkn	08638365696	11	099	03263	hkn1	10.384921982026151	106.81312537164855	f
550	2024-11-21 06:39:16.928894+00	2024-11-21 06:39:16.928894+00	\N	796	hân	0668566693	10	084	02809	hdjdbc	10.716870004400937	106.97743131897184	t
583	2024-11-21 06:40:46.643795+00	2024-11-21 06:40:46.643795+00	\N	796	hkn	0668696858	10	084	02812	hsjej	10.694681301624835	106.65093509942092	f
616	2024-11-21 08:41:21.065088+00	2024-11-21 08:41:21.065088+00	\N	862	hân	0965328456	02	024	00688	ngõ 67	10.910389142402487	106.30025114013249	t
649	2024-11-21 08:53:52.184974+00	2024-11-21 08:53:52.184974+00	\N	862	han ln	08531246795	01	001	00004	hẻm 65	10.32684855871716	106.36429603921886	f
650	2024-11-21 08:54:24.554858+00	2024-11-21 08:54:24.554858+00	\N	862	lnh	0865386535	79	778	27484	dươngd 60	10.187465025525974	106.86075123546988	f
651	2024-11-21 09:42:53.339312+00	2024-11-21 09:42:53.339312+00	\N	895	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	t
652	2024-11-21 09:43:45.978748+00	2024-11-21 09:43:45.978748+00	\N	895	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	f
653	2024-11-22 08:27:50.477428+00	2024-11-22 08:27:50.477428+00	\N	895	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	f
654	2024-11-22 08:28:35.26715+00	2024-11-22 08:28:35.26715+00	\N	895	hkn2	09683953683	64	623	23617	55 hai bà trưng	10.903530872106048	106.5675667739202	f
655	2024-11-23 04:02:54.105838+00	2024-11-23 04:02:54.105838+00	\N	896	hkn	0968685686	11	097	03178	bdhd	10.487121165685204	106.5979298185143	t
656	2024-11-23 04:03:41.910622+00	2024-11-23 04:03:41.910622+00	\N	896	hkn2	8865949565	45	468	19600	hdnfnfjfif	10.337661780271675	107.15084608993939	f
657	2024-11-25 10:05:40.112363+00	2024-11-25 10:05:40.112363+00	\N	897	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	t
658	2024-11-25 10:06:58.596938+00	2024-11-25 10:06:58.596938+00	\N	897	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	f
659	2024-11-26 07:41:27.874985+00	2024-11-26 07:41:27.874985+00	\N	898	khánh vũ	0968568685	06	062	01945	jdndbd	11.02507740955514	106.7376653832702	t
660	2024-11-26 07:50:40.721616+00	2024-11-26 07:50:40.721616+00	\N	898	hkn	0896836856	79	769	27100	quán bún đậu	10.323660175589573	107.11438126186424	f
18	2024-10-21 10:00:53.240544+00	2024-11-12 03:26:58.919401+00	\N	1	Stella Heathcote MD	922-319-0321	79	769	26800	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	t
661	2024-11-30 22:07:16.524663+00	2024-11-30 22:07:16.524663+00	\N	899	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	t
662	2024-11-30 22:10:53.946745+00	2024-11-30 22:10:53.946745+00	\N	899	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	f
663	2024-12-02 04:28:44.440404+00	2024-12-02 04:28:44.440404+00	\N	1	abc	0852134679	02	027	00772	haha	10.938755399831365	106.90148455651678	f
\.


--
-- Data for Name: customer_products; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.customer_products (id, created_at, updated_at, deleted_at, customer_id, product_id, price) FROM stdin;
1	2024-10-17 09:55:37.617862+00	2024-10-17 09:55:37.617862+00	\N	4	1	10000.00
2	2024-10-17 10:06:21.26202+00	2024-10-17 10:06:21.26202+00	\N	5	1	10000.00
4	2024-11-04 16:15:11.71987+00	2024-11-04 16:15:11.71987+00	\N	6	1	10000.00
5	2024-11-04 16:15:11.725076+00	2024-11-04 16:15:11.725076+00	\N	6	3	20000.00
6	2024-11-04 16:17:11.04316+00	2024-11-04 16:17:11.04316+00	\N	7	1	1000.00
7	2024-11-04 16:17:11.04553+00	2024-11-04 16:17:11.04553+00	\N	7	6	20000.00
8	2024-11-05 07:11:45.106178+00	2024-11-05 07:11:45.106178+00	\N	14	3	100.00
9	2024-11-05 07:11:45.108411+00	2024-11-05 07:11:45.108411+00	\N	14	1	10.00
10	2024-11-08 06:45:42.216021+00	2024-11-08 06:45:42.216021+00	\N	15	1	10000.00
11	2024-11-08 06:45:42.223144+00	2024-11-08 06:45:42.223144+00	\N	15	6	20000.00
12	2024-11-12 02:36:08.650254+00	2024-11-12 02:36:08.650254+00	\N	16	1	10000.00
13	2024-11-12 02:36:08.654408+00	2024-11-12 02:36:08.654408+00	\N	16	3	20000.00
3	2024-10-17 10:06:21.338336+00	2024-10-17 10:06:21.338336+00	\N	4	3	20000.00
14	2024-11-15 07:43:58.32187+00	2024-11-15 07:43:58.32187+00	\N	23	1	10000.00
15	2024-11-15 07:43:58.325769+00	2024-11-15 07:43:58.325769+00	\N	23	3	20000.00
16	2024-11-15 07:45:38.747017+00	2024-11-15 07:45:38.747017+00	\N	39	20	1000.00
17	2024-11-15 07:46:34.721905+00	2024-11-15 07:46:34.721905+00	\N	52	20	1000.00
18	2024-11-15 07:47:34.145421+00	2024-11-15 07:47:34.145421+00	\N	75	20	1000.00
19	2024-11-15 07:48:17.618664+00	2024-11-15 07:48:17.618664+00	\N	96	1	10000.00
20	2024-11-15 07:48:17.620844+00	2024-11-15 07:48:17.620844+00	\N	96	3	20000.00
21	2024-11-15 07:48:32.933047+00	2024-11-15 07:48:32.933047+00	\N	100	20	1000.00
22	2024-11-15 07:50:03.633601+00	2024-11-15 07:50:03.633601+00	\N	112	20	1000.00
23	2024-11-15 07:51:55.604254+00	2024-11-15 07:51:55.604254+00	\N	117	1	10000.00
24	2024-11-15 07:51:55.689821+00	2024-11-15 07:51:55.689821+00	\N	117	3	20000.00
25	2024-11-15 07:55:55.968222+00	2024-11-15 07:55:55.968222+00	\N	145	20	1000.00
26	2024-11-15 07:57:51.515882+00	2024-11-15 07:57:51.515882+00	\N	146	20	1000.00
27	2024-11-15 08:06:30.017881+00	2024-11-15 08:06:30.017881+00	\N	155	1	10000.00
28	2024-11-15 08:06:30.111471+00	2024-11-15 08:06:30.111471+00	\N	155	3	20000.00
29	2024-11-15 08:06:46.983337+00	2024-11-15 08:06:46.983337+00	\N	157	3	20000.00
30	2024-11-15 08:06:47.073375+00	2024-11-15 08:06:47.073375+00	\N	157	1	10000.00
31	2024-11-15 08:09:58.239432+00	2024-11-15 08:09:58.239432+00	\N	158	1	10000.00
32	2024-11-15 08:09:58.332202+00	2024-11-15 08:09:58.332202+00	\N	158	3	20000.00
33	2024-11-15 08:10:10.620382+00	2024-11-15 08:10:10.620382+00	\N	159	20	1000.00
34	2024-11-15 08:10:57.938765+00	2024-11-15 08:10:57.938765+00	\N	164	20	1000.00
35	2024-11-15 08:11:48.413841+00	2024-11-15 08:11:48.413841+00	\N	169	1	10000.00
36	2024-11-15 08:11:48.416254+00	2024-11-15 08:11:48.416254+00	\N	169	3	20000.00
37	2024-11-15 08:13:12.096851+00	2024-11-15 08:13:12.096851+00	\N	172	20	1000.00
38	2024-11-15 08:16:01.670617+00	2024-11-15 08:16:01.670617+00	\N	175	20	1000.00
39	2024-11-18 04:58:36.062883+00	2024-11-18 04:58:36.062883+00	\N	347	20	11111.00
40	2024-11-18 04:58:36.070327+00	2024-11-18 04:58:36.070327+00	\N	347	4	111112.00
72	2024-11-18 05:01:04.250793+00	2024-11-18 05:01:04.250793+00	\N	409	20	11111.00
73	2024-11-18 05:01:04.253631+00	2024-11-18 05:01:04.253631+00	\N	409	4	111112.00
105	2024-11-18 05:32:03.873351+00	2024-11-18 05:32:03.873351+00	\N	442	20	1111.00
106	2024-11-18 05:32:03.876339+00	2024-11-18 05:32:03.876339+00	\N	442	4	11111.00
138	2024-11-18 07:55:15.92869+00	2024-11-18 07:55:15.92869+00	\N	475	20	40000.00
139	2024-11-18 07:55:15.932909+00	2024-11-18 07:55:15.932909+00	\N	475	3	10000.00
140	2024-11-18 07:55:15.937558+00	2024-11-18 07:55:15.937558+00	\N	475	4	20000.00
171	2024-11-19 04:28:38.9699+00	2024-11-19 04:28:38.9699+00	\N	580	58	0.00
172	2024-11-19 04:28:38.974614+00	2024-11-19 04:28:38.974614+00	\N	580	20	0.00
204	2024-11-19 04:33:27.231363+00	2024-11-19 04:33:27.231363+00	\N	607	20	0.00
205	2024-11-19 04:33:27.234742+00	2024-11-19 04:33:27.234742+00	\N	607	25	0.00
206	2024-11-19 04:33:27.237382+00	2024-11-19 04:33:27.237382+00	\N	607	58	0.00
237	2024-11-19 04:35:09.234186+00	2024-11-19 04:35:09.234186+00	\N	640	25	799999.00
238	2024-11-19 04:35:09.237883+00	2024-11-19 04:35:09.237883+00	\N	640	20	80000.00
239	2024-11-19 04:35:09.240432+00	2024-11-19 04:35:09.240432+00	\N	640	58	10000.00
270	2024-11-19 04:41:55.154064+00	2024-11-19 04:41:55.154064+00	\N	673	58	0.00
271	2024-11-19 04:41:55.157987+00	2024-11-19 04:41:55.157987+00	\N	673	91	0.00
303	2024-11-19 04:45:05.852027+00	2024-11-19 04:45:05.852027+00	\N	706	91	0.00
336	2024-11-19 07:49:14.133425+00	2024-11-19 07:49:14.133425+00	\N	739	124	20000.00
337	2024-11-19 08:24:34.331395+00	2024-11-19 08:24:34.331395+00	\N	740	126	20000.00
338	2024-11-19 09:57:01.518853+00	2024-11-19 09:57:01.518853+00	\N	741	1	10000.00
339	2024-11-19 09:57:01.521756+00	2024-11-19 09:57:01.521756+00	\N	741	3	20000.00
340	2024-11-19 10:14:28.181521+00	2024-11-19 10:14:28.181521+00	\N	752	1	10000.00
341	2024-11-19 10:14:28.185023+00	2024-11-19 10:14:28.185023+00	\N	752	3	20000.00
342	2024-11-20 06:11:02.706584+00	2024-11-20 06:11:02.706584+00	\N	756	134	100000.00
343	2024-11-20 06:11:02.710534+00	2024-11-20 06:11:02.710534+00	\N	756	4	200000.00
344	2024-11-20 07:09:10.004522+00	2024-11-20 07:09:10.004522+00	\N	757	136	1000.00
345	2024-11-20 07:22:54.123514+00	2024-11-20 07:22:54.123514+00	\N	758	137	10000.00
346	2024-11-20 08:26:02.046779+00	2024-11-20 08:26:02.046779+00	\N	759	138	200.00
347	2024-11-20 08:36:49.465718+00	2024-11-20 08:36:49.465718+00	\N	760	139	100.00
348	2024-11-20 09:58:39.551018+00	2024-11-20 09:58:39.551018+00	\N	761	140	10000.00
349	2024-11-20 10:10:32.51743+00	2024-11-20 10:10:32.51743+00	\N	762	135	1111.00
350	2024-11-21 06:18:29.75003+00	2024-11-21 06:18:29.75003+00	\N	763	134	100.00
383	2024-11-21 06:39:16.933886+00	2024-11-21 06:39:16.933886+00	\N	796	140	200.00
416	2024-11-21 08:41:21.070824+00	2024-11-21 08:41:21.070824+00	\N	862	141	1000.00
449	2024-11-21 09:42:53.466171+00	2024-11-21 09:42:53.466171+00	\N	895	174	400.00
450	2024-11-23 04:02:54.234061+00	2024-11-23 04:02:54.234061+00	\N	896	177	1000.00
451	2024-11-25 10:05:40.238257+00	2024-11-25 10:05:40.238257+00	\N	897	178	1000.00
452	2024-11-26 07:41:28.001005+00	2024-11-26 07:41:28.001005+00	\N	898	179	60000.00
453	2024-11-30 22:07:16.650906+00	2024-11-30 22:07:16.650906+00	\N	899	126	10000.00
454	2024-11-30 22:07:16.776084+00	2024-11-30 22:07:16.776084+00	\N	899	4	20000.00
455	2024-11-30 22:07:16.901113+00	2024-11-30 22:07:16.901113+00	\N	899	180	50000.00
\.


--
-- Data for Name: customer_routes; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.customer_routes (id, created_at, updated_at, deleted_at, customer_id, name, address_from_id, address_to_id, route_pricing, driver_pricing, distance) FROM stdin;
2	2024-10-21 10:14:25.881273+00	2024-10-21 10:14:25.881273+00	2024-10-21 10:14:25.881273+00	1	Kristopher Nikolaus	3	4	1000.00	1000.00	7100.50
1	2024-10-21 10:14:21.889444+00	2024-10-21 10:14:21.889444+00	\N	1	Mandy Sporer	3	4	1000000.00	500000.00	7100.50
3	2024-10-22 01:36:20.279207+00	2024-10-22 01:36:20.279207+00	\N	1	Gretchen Moen	4	18	590000.00	250000.00	3303.00
4	2024-10-22 01:36:29.107409+00	2024-10-22 01:36:29.107409+00	\N	1	Natasha Hilpert	13	18	8900000.00	450000.00	6565.90
5	2024-10-22 01:36:59.46929+00	2024-10-22 01:44:51.70072+00	\N	2	Vernon Gerhold	14	5	1300000.00	700000.00	12330.50
6	2024-11-07 07:38:39.691473+00	2024-11-07 07:38:39.691473+00	\N	2	AB	14	14	10000.00	10000.00	0.00
7	2024-11-07 07:39:20.680351+00	2024-11-07 07:39:20.680351+00	\N	2	priceDriverController	5	5	2000.00	20100.00	0.00
8	2024-11-07 21:40:00.270445+00	2024-11-07 21:40:00.270445+00	\N	6	A-B	52	53	1231110.00	123000.00	9173298.20
9	2024-11-08 07:02:15.571929+00	2024-11-08 07:02:15.571929+00	\N	15	hkn-hkn	54	55	100000.00	10000.00	0.00
10	2024-11-17 21:58:42.299759+00	2024-11-17 21:58:42.299759+00	\N	7		85	22	20000.00	30000.00	4929535.10
11	2024-11-18 08:00:32.094201+00	2024-11-18 08:00:32.094201+00	\N	7	A toi B	85	251	200.00	400.00	0.00
44	2024-11-18 14:49:37.837361+00	2024-11-18 14:49:37.837361+00	\N	7	a-c	22	85	120000.00	3360000.00	4927035.80
45	2024-11-18 14:54:56.87324+00	2024-11-18 14:54:56.87324+00	\N	7	a-c	251	22	1200.00	3360000.00	4929535.10
46	2024-11-18 14:55:45.714608+00	2024-11-18 14:55:45.714608+00	\N	7	a-c	251	85	12010.00	3360000.00	0.00
47	2024-11-18 14:56:04.341397+00	2024-11-18 14:56:04.341397+00	\N	7	a-c	22	251	12010.00	3360000.00	4927035.80
48	2024-11-18 15:01:04.243197+00	2024-11-18 15:01:04.243197+00	\N	7	a-c	284	22	12010.00	3360000.00	4929535.10
49	2024-11-18 15:02:21.988571+00	2024-11-18 15:02:21.988571+00	\N	7	ab-c	284	251	11111.00	22222.00	0.00
50	2024-11-18 15:03:14.523333+00	2024-11-18 15:03:14.523333+00	\N	7	ab-c	22	284	1111.00	2222.00	4927035.80
51	2024-11-19 06:59:40.247647+00	2024-11-19 06:59:40.247647+00	\N	640	A-B-C-D	353	452	100000.00	200000.00	0.00
52	2024-11-19 07:01:20.432625+00	2024-11-19 07:01:20.432625+00	\N	640	an uong	453	452	11111.00	11121.00	0.00
53	2024-11-19 07:02:27.68162+00	2024-11-19 07:02:27.68162+00	\N	640	IT	452	453	11111.00	22111.00	0.00
54	2024-11-19 07:28:59.729773+00	2024-11-19 07:28:59.729773+00	\N	640	bao a-b	454	455	50000.00	20000.00	50923.90
55	2024-11-19 08:02:46.319022+00	2024-11-19 08:02:46.319022+00	\N	739	tuyến ab	461	462	5000.00	20000.00	61526.50
56	2024-11-19 08:28:59.266606+00	2024-11-19 08:28:59.266606+00	\N	740	han le 2	463	464	20000.00	1000.00	49598.40
57	2024-11-20 06:19:25.645289+00	2024-11-20 06:19:25.645289+00	\N	752	lộ trình 1	467	470	200000.00	100000.00	0.00
58	2024-11-20 08:27:00.283134+00	2024-11-20 08:27:00.283134+00	\N	756	bao-linh	475	468	11111.00	209900.00	89495.20
59	2024-11-20 09:00:36.025225+00	2024-11-20 09:00:36.025225+00	\N	760	www	479	480	444.00	222.00	65575.80
60	2024-11-20 09:01:37.609982+00	2024-11-20 09:01:37.609982+00	\N	760		480	479	1000.00	20000.00	65524.40
61	2024-11-21 06:41:17.883705+00	2024-11-21 06:41:17.883705+00	\N	796	tuyến cb	550	583	10000.00	1000.00	51303.10
94	2024-11-25 06:48:16.925784+00	2024-11-25 06:48:16.925784+00	\N	895	lộ trình 1	651	653	10000.00	10000.00	89827.80
95	2024-11-25 06:48:17.382622+00	2024-11-25 06:48:17.382622+00	\N	895	lộ trình 1	651	653	10000.00	10000.00	89827.80
96	2024-11-26 04:07:48.24944+00	2024-11-26 04:07:48.24944+00	\N	897	lộ trình ab	657	658	25000.00	500000.00	136971.10
97	2024-11-30 22:11:33.130154+00	2024-11-30 22:11:33.130154+00	\N	899	abc-yu	661	662	12000.00	500000.00	99100.20
\.


--
-- Data for Name: customers; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.customers (id, created_at, updated_at, deleted_at, customer_name, email, phone_number, company_name, tax_code, description) FROM stdin;
1	2024-10-17 03:05:38.300856+00	2024-10-17 03:05:38.300856+00	\N	Mrs. Sara Abbott	Nelson_Smith@gmail.com	575-737-7487	Ferry - Russel	688-320-8495	description
2	2024-10-17 03:26:48.067378+00	2024-10-17 03:26:48.067378+00	\N	Elvira Von	Sheila18@yahoo.com	894-684-1857	Dickens - Gislason	259-473-3598	description
3	2024-10-17 07:11:24.818444+00	2024-10-17 07:11:24.818444+00	\N	Eduardo Hintz	Magali.Harris@hotmail.com	697-479-0520	Stokes LLC	457-569-1779	description
4	2024-10-17 09:55:37.453811+00	2024-10-17 09:55:37.453811+00	\N	Shari Wehner	Ron_Parisian@yahoo.com	531-419-2373	Beier Group	391-592-9262	description
5	2024-10-17 10:06:21.092465+00	2024-10-17 10:06:21.092465+00	\N	Tony Harris	Miguel_West@yahoo.com	298-408-7715	Skiles and Sons	970-363-1367	description
6	2024-11-04 16:15:11.701659+00	2024-11-04 16:15:11.701659+00	\N	a	cu@ggmail.com	232323232	AB	12334	111
7	2024-11-04 16:17:11.037361+00	2024-11-04 16:17:11.037361+00	\N	ab	ab@gm.com	12121212	12345	ab	ab
39	2024-11-15 07:45:38.740006+00	2024-11-15 07:45:38.740006+00	2024-11-05 07:11:45.098422+00	bao nguyen A	baoA@gmail.com	0987654345	HKN	109876	ko
152	2024-11-15 08:02:54.750447+00	2024-11-15 08:02:54.750447+00	2024-11-05 07:11:45.098422+00	BaoABCDEDFDE	bao9991999@gmail.com	08693072189	HKN	78877778090	ko
16	2024-11-12 02:36:08.564812+00	2024-11-12 02:36:08.564812+00	2024-11-05 07:11:45.098422+00	Lê Nhã Hân	han123@gmail.com	0123456789	HKN	0123456789	description
23	2024-11-15 07:43:58.308908+00	2024-11-15 07:43:58.308908+00	2024-11-05 07:11:45.098422+00	Gloria Powlowski DVM	Violette61@gmail.com	793-204-7295	Weissnat - Raynor	726-632-9900	description
151	2024-11-15 08:01:19.900961+00	2024-11-15 08:01:19.900961+00	2024-11-05 07:11:45.098422+00	BaoABCDEDFD	bao9991989@gmail.com	08693072108	HKN	7887777800	ko
159	2024-11-15 08:10:10.615578+00	2024-11-15 08:10:10.615578+00	2024-11-05 07:11:45.098422+00	BaoABCDEDFDE	bao999189@gmail.com	08693072188	HKN	78877778098	ko
176	2024-11-15 08:16:23.735558+00	2024-11-15 08:16:23.735558+00	2024-11-05 07:11:45.098422+00	BaoABCDEDF	bao99998171@gmail.com	0186930721971	HKN	109871609071	ko
54	2024-11-15 07:46:53.236806+00	2024-11-15 07:46:53.236806+00	2024-11-05 07:11:45.098422+00	bao nguyen ABC	baoABC@gmail.com	09876543762	HKN	10987612	ko
52	2024-11-15 07:46:34.685176+00	2024-11-15 07:46:34.685176+00	2024-11-05 07:11:45.098422+00	bao nguyen AB	baoAB@gmail.com	09876543761	HKN	1098761	ko
84	2024-11-15 07:47:54.433944+00	2024-11-15 07:47:54.433944+00	2024-11-05 07:11:45.098422+00	BaoA ABC	baoABCE@gmail.com	09876543790	HKN	109876081	ko
146	2024-11-15 07:57:51.510723+00	2024-11-15 07:57:51.510723+00	2024-11-05 07:11:45.098422+00	BaoABCDEDFD	bao999198@gmail.com	08693072110	HKN	7887777887	ko
100	2024-11-15 07:48:32.927152+00	2024-11-15 07:48:32.927152+00	2024-11-05 07:11:45.098422+00	BaoABCDE	baoABCEF@gmail.com	0869307217	HKN	109876082	ko
96	2024-11-15 07:48:17.613514+00	2024-11-15 07:48:17.613514+00	2024-11-05 07:11:45.098422+00	hanle	hanle@gmail.com	1234567890	HKN	12345	description
116	2024-11-15 07:51:19.676751+00	2024-11-15 07:51:19.676751+00	2024-11-05 07:11:45.098422+00	BaoABCDEDF	bao99998@gmail.com	0869307219	HKN	109876079	ko
112	2024-11-15 07:50:03.627764+00	2024-11-15 07:50:03.627764+00	2024-11-05 07:11:45.098422+00	BaoABCDED	bao9999@gmail.com	0869307218	HKN	109876076	ko
14	2024-11-05 07:11:45.098422+00	2024-11-05 07:11:45.098422+00	\N	bao	bao@gmail.com	0987654321	HKN	09182873	ko co
311	2024-11-18 04:56:14.412626+00	2024-11-18 04:56:14.412626+00	\N	Bao	bao12@gmail.com	0987654320	HKN	09090	ko
347	2024-11-18 04:58:36.046884+00	2024-11-18 04:58:36.046884+00	\N	Bao	bao1234@gmail.com	0987654300	HKN	090901111	ko
409	2024-11-18 05:01:04.23277+00	2024-11-18 05:01:04.23277+00	\N	Bao	bao12345@gmail.com	0987654301	HKN	090901112	ko
442	2024-11-18 05:32:03.856586+00	2024-11-18 05:32:03.856586+00	\N	a	bao209@gmail.com	0990299922	HKN	232323212	ko
475	2024-11-18 07:55:15.90881+00	2024-11-18 07:55:15.90881+00	\N	bao dep trai	bao2001@gmail.com	0987654342	HKN	01932039	ko
580	2024-11-19 04:28:38.955165+00	2024-11-19 04:28:38.955165+00	\N	Lê Nhã Hân	lenhahan123@gmail.com	0987654335	Công ty TNHH Hoà Kiến Nhân	1402053388	123
607	2024-11-19 04:33:27.212842+00	2024-11-19 04:33:27.212842+00	\N	Lê Nhã Hân Heo	han2002@gmail.com	0869352147	hkn	086932154708	ko
640	2024-11-19 04:35:09.202097+00	2024-11-19 04:35:09.202097+00	\N	Bao AE	baoER@gmail.com	0918275643	hknko	19389183813	ko
673	2024-11-19 04:41:55.141678+00	2024-11-19 04:41:55.141678+00	\N	Lê Nhã Hân	lenhahan456@gmail.com	0899364555	Hoà Kiến Nhân	4563838494	abc
706	2024-11-19 04:45:05.835091+00	2024-11-19 04:45:05.835091+00	\N	Lê Nhã Hân	heo@gmail.com	0852369741	hkn	94931518181616	ko
739	2024-11-19 07:49:14.119529+00	2024-11-19 07:49:14.119529+00	\N	hân lê	hanle123@gmail.com	0346249552	hkn	45673186835	ko
740	2024-11-19 08:24:34.320411+00	2024-11-19 08:24:34.320411+00	\N	hân lê 2	hanle2@gmail.com	0834692563	hkn	6468989	ghi chu
741	2024-11-19 09:57:01.508218+00	2024-11-19 09:57:01.508218+00	\N	han le 3	hanle456@	0354567846	hkn4	2353424	description
747	2024-11-19 10:04:04.174565+00	2024-11-19 10:04:04.174565+00	\N	han le 4	hanle656@	0364567846	hkn4	2653424	description
756	2024-11-20 06:11:02.665798+00	2024-11-20 06:11:02.665798+00	\N	Bảo đồng nát	freedom@gmajl.com	0869307210	TNHH Đồng Nát	085236914725	ko
757	2024-11-20 07:09:09.993814+00	2024-11-20 07:09:09.993814+00	\N	hân nhã 	han@gmail.com	0986543529	hknc	867464897888	jj
758	2024-11-20 07:22:54.115941+00	2024-11-20 07:22:54.115941+00	\N	hân nhã 100	djnd@gmail.com	0965346856	snsj	46468686	jj
761	2024-11-20 09:58:39.534691+00	2024-11-20 09:58:39.534691+00	\N	hân test đơn dự án	jsjdnfj	0563583635	hkn	9669899686	hjnnj
763	2024-11-21 06:18:29.732142+00	2024-11-21 06:18:29.732142+00	\N	nhã hân 7	hablejsjs	08694683668	hkn	855646	hjj
796	2024-11-21 06:39:16.918506+00	2024-11-21 06:39:16.918506+00	\N	hân nhã 70	dikdfb	09686869687	hkn	879797	hjj
862	2024-11-21 08:41:21.058806+00	2024-11-21 08:41:21.058806+00	\N	khách hàng mua hộp hàng	hanle89@gmail.com	0856942365	hkn	123506884864	hjjbkh
117	2024-11-15 07:51:55.414199+00	2024-11-15 07:51:55.414199+00	2024-11-05 07:11:45.098422+00	Shelley Raynor	Ansley.Heller6@gmail.com	354-283-1835	Hudson - O'Kon	992-523-7150	description
75	2024-11-15 07:47:34.140451+00	2024-11-15 07:47:34.140451+00	2024-11-05 07:11:45.098422+00	Bao ABC	baoABCD@gmail.com	09876543798	HKN	10987609	ko
157	2024-11-15 08:06:46.7983+00	2024-11-15 08:06:46.7983+00	2024-11-05 07:11:45.098422+00	Claudia Grant	vu12@gmail.com	0123452	Dach, Moen and Stoltenberg	1254	description
155	2024-11-15 08:06:29.75336+00	2024-11-15 08:06:29.75336+00	2024-11-05 07:11:45.098422+00	Bertha Daugherty	vu1@gmail.com	0123451	Satterfield, Anderson and Tremblay	123	description
158	2024-11-15 08:09:58.041231+00	2024-11-15 08:09:58.041231+00	2024-11-05 07:11:45.098422+00	Angelica Leannon Sr.	vu12a@gmail.com	01123452	Sporer LLC	12154	description
164	2024-11-15 08:10:57.933997+00	2024-11-15 08:10:57.933997+00	2024-11-05 07:11:45.098422+00	BaoABCDEDFDE	bao99918998@gmail.com	08693072199	HKN	78877778095	ko
15	2024-11-08 06:45:42.201937+00	2024-11-08 06:45:42.201937+00	2024-11-05 07:11:45.098422+00	Linh	linh@gmail.com	0896574231	Hoa Kien Nhan	2536194870	ko co
145	2024-11-15 07:55:55.775192+00	2024-11-15 07:55:55.775192+00	2024-11-05 07:11:45.098422+00	BaoABCDEDFD	bao999984@gmail.com	08693072196	HKN	1098760901	ko
173	2024-11-15 08:15:10.106279+00	2024-11-15 08:15:10.106279+00	2024-11-05 07:11:45.098422+00	BaoABCDEDF	bao999987@gmail.com	08693072197	HKN	109876090	ko
172	2024-11-15 08:13:12.009987+00	2024-11-15 08:13:12.009987+00	2024-11-05 07:11:45.098422+00	BaoABCDEDFDEE	bao999189981@gmail.com	086930721601	HKN	788777780601	ko
175	2024-11-15 08:16:01.655589+00	2024-11-15 08:16:01.655589+00	2024-11-05 07:11:45.098422+00	BaoABCDEDF	bao9999817@gmail.com	018693072197	HKN	10987160907	ko
169	2024-11-15 08:11:48.408145+00	2024-11-15 08:11:48.408145+00	2024-11-05 07:11:45.098422+00	Caleb Gerhold	vu1a2a@gmail.com	001123452	Mertz - Kunze	121540	description
752	2024-11-19 10:14:28.169532+00	2024-11-19 10:14:28.169532+00	\N	nha han 1	hanle27@gmail.com	0987654567	hkn	3436453	description
759	2024-11-20 08:26:02.036447+00	2024-11-20 08:26:02.036447+00	\N	khánh vũ 3	khanhvu@gmail.com	0564868596	hkn	65959	jj
760	2024-11-20 08:36:49.454027+00	2024-11-20 08:36:49.454027+00	\N	linh siêu nhân	dfgvv	0852364755	hkn	98899	bjj
762	2024-11-20 10:10:32.506982+00	2024-11-20 10:10:32.506982+00	\N	Bao	1111sa@MNK	12112121212	1DHSAJD	1212121	SA0
895	2024-11-21 09:42:53.214195+00	2024-11-21 09:42:53.214195+00	\N	khách hàng mua tro	tro@gmail.com	099686869	hkn	6858856	hh
896	2024-11-23 04:02:53.980236+00	2024-11-23 04:02:53.980236+00	\N	khách hàng nón lá	jabdb	089686863	hkn	787664846446	bhj
897	2024-11-25 10:05:39.985774+00	2024-11-25 10:05:39.985774+00	\N	KH 100	hkn@gmail.com	099656853	hkn	868589	hhh
898	2024-11-26 07:41:27.74826+00	2024-11-26 07:41:27.74826+00	\N	khách mua bún đậu	bundau@gmail.com	0896523658	hkn	076787676484648	vbn
899	2024-11-30 22:07:16.398839+00	2024-11-30 22:07:16.398839+00	\N	kh bug	bug@gmail.com	098765473	bug tnhh	3829083209	ko
\.


--
-- Data for Name: department; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.department (id, created_at, updated_at, deleted_at, name, description, company_id) FROM stdin;
4	2024-06-07 06:37:56.18288+00	2024-06-07 06:37:56.18288+00	\N	it	phòng it	1
1	2024-06-07 06:36:08.190628+00	2024-06-07 06:36:08.190628+00	\N	head_quarter	phòng giám đốc	1
2	2024-06-07 06:35:34.197001+00	2024-06-07 06:35:34.197001+00	\N	business	phòng kinh doanh	1
3	2024-06-07 06:35:10.37243+00	2024-06-07 06:35:10.37243+00	\N	accountant	phòng kế toán	1
5	2024-06-07 07:53:23.959742+00	2024-06-07 07:53:23.959742+00	\N	international_sale	kinh doanh quốc tế	1
6	2024-07-02 01:46:51.021473+00	2024-07-02 01:46:51.021473+00	2024-07-02 01:48:08.000787+00	test	\N	1
\.


--
-- Data for Name: drivers; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.drivers (id, created_at, updated_at, deleted_at, owner_id, name, day_of_birth, phone_number, email, password, media_license_front, media_license_back, province, district, ward, detail_address, lat, long, start_date, vehicle_id, driver_status) FROM stdin;
60	2024-11-20 10:19:24.204907+00	2024-11-20 10:22:30.90215+00	\N	4	le nha han	2000	0856842655	hanl3@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	08	070	02206	ngõ t6	10.189242933223772	106.97151113451348	1731375492510	264	active
1	2024-10-22 02:21:18.688979+00	2024-11-19 03:07:13.756511+00	\N	4	Julia.Greenholt	2001	379-367-7566	Jammie5@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Mrs.	Sr.	Dr.	la	1.8387	69.7358	316-839-1787	1	inactive
59	2024-11-20 09:56:56.927395+00	2024-11-21 06:42:40.717512+00	\N	4	tài xế chở xi măng	2000	0868688669	hhhjmkl	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	11	097	03190	ngõ 57	11.130404763101781	106.96034144806079	1731375492510	261	active
51	2024-11-20 07:33:57.640281+00	2024-11-20 07:33:57.640281+00	\N	4	linh 1	2000	0542945384	linh187@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	02	029	00877	đường 19	10.549199590167127	106.69325818664313	1732119122591	252	inactive
52	2024-11-20 07:41:30.996283+00	2024-11-20 07:41:30.996283+00	\N	4	linh 2	1999	0856321497	freedoiv27@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	04	042	01291	số 10	10.639883617778086	106.48917749063476	1732119578364	253	inactive
50	2024-11-20 07:21:01.845854+00	2024-11-20 07:21:01.845854+00	\N	4	hân hân 1	2000	0856472395	khanh147@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	33	329	12160	đường 3	11.067346523979355	106.33429516947305	1732066692510	251	inactive
55	2024-11-20 08:35:12.633404+00	2024-11-20 08:47:35.997726+00	\N	4	bảo 89	2000	0545412845	dbsj	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	06	060	01861	ccf	10.66471045707578	106.6397371463901	1731893892510	257	active
54	2024-11-20 08:23:30.593704+00	2024-11-20 08:23:30.593704+00	\N	4	khánh vũ 2	2000	0865243856	khann78@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	95	960	31981	kkdksks	10.20693369784305	106.43191290874307	1732122100781	255	inactive
3	2024-10-22 02:29:33.839558+00	2024-10-22 02:29:33.839558+00	\N	4	Ethan34	1990	697-956-3715	Eddie_Weimann1@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Mrs.	III	Dr.	mo	83.9179	115.9238	422-299-0779	3	active
58	2024-11-20 09:14:41.360326+00	2024-11-20 09:16:04.024211+00	\N	4	bao khung	2001	098754873	78@gmail,comn	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	02	027	00778	vvvv	10.80610476830972	106.33036761022812	1731980292510	260	active
46	2024-11-20 03:25:41.352237+00	2024-11-20 03:25:41.352237+00	\N	4	saveDayStart	2001	0987654343	bacba@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	02	026	00715	24 an binh	10.237783619999076	106.89560163006243	1732103945883	28	inactive
47	2024-11-20 06:49:18.192217+00	2024-11-20 06:49:18.192217+00	\N	4	nha han 3	2002	0869648268	hanle27@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	04	042	01294	ngõ 66	11.080209903044034	106.8065637217615	1732116410386	249	inactive
49	2024-11-20 07:04:00.393256+00	2024-11-20 07:04:00.393256+00	\N	4	hân lê	2000	0987654653	khanh127@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	52	549	21913	đường 7	10.38318483026855	106.36154935157691	1732117324883	250	inactive
48	2024-11-20 06:52:28.040687+00	2024-11-20 06:52:28.040687+00	\N	4	khánh vũ	2000	0987645238	khanh27@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	92	918	31169	giữa sông	10.428280252456624	106.89262448886839	1732116606585	248	inactive
53	2024-11-20 08:20:50.389744+00	2024-11-20 08:20:50.389744+00	\N	4	linh 3	2000	08523116999	linh616@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	02	026	00721	số 10	10.69302232917317	107.0463332424085	1732119293043	254	inactive
4	2024-10-22 03:33:28.386853+00	2024-10-22 03:33:28.386853+00	\N	4	Mallie63	1998	772-292-0272	Bria.Denesik98@yahoo.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Ms.	DDS	Mrs.	pl	-71.4994	69.6836	407-269-4942	4	active
5	2024-10-22 04:17:51.214204+00	2024-10-22 04:17:51.214204+00	\N	4	Amanda.Heidenreich33	1998	817-701-20311	Elissa.Durgan@hotmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Dr.	III	Ms.	cs	-81.5627	-14.4737	547-647-5317	5	active
6	2024-10-22 04:17:51.214204+00	2024-10-22 04:17:51.214204+00	\N	4	good.abc	1998	817-701-20315	abc@hotmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Dr.	III	Ms.	cs	-81.5627	-14.4737	547-647-5317	6	active
7	2024-10-22 04:17:51.214204+00	2024-10-22 04:17:51.214204+00	\N	4	good.zxc	2000	817-701-20314	zxc@hotmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Dr.	III	Ms.	cs	-81.5627	-14.4737	547-647-5317	7	active
8	2024-10-22 04:17:51.214204+00	2024-10-22 04:17:51.214204+00	\N	4	good.qwe	1987	817-701-20312	qwe@hotmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Dr.	III	Ms.	cs	-81.5627	-14.4737	547-647-5317	8	active
131	2024-11-21 09:40:46.44578+00	2024-11-21 10:07:05.931451+00	\N	4	nh 1	2000	0896523658	nh1@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	04	042	01294	hẻm	10.73032621148073	106.42230304994203	1731980292510	399	active
9	2024-10-22 04:17:51.214204+00	2024-10-22 04:17:51.214204+00	\N	4	good.asd	1998	817-701-20313	asd@hotmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Dr.	III	Ms.	cs	-81.5627	-14.4737	547-647-5317	9	active
10	2024-11-07 09:33:00.370707+00	2024-11-07 09:33:00.370707+00	\N	4	Adelbert.Gibson	1998	914-526-8266	Keara8@hotmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Mr.	V	Mrs.	st	12.1837	63.8690	725-387-7245	10	inactive
11	2024-11-07 09:36:01.333678+00	2024-11-07 09:36:01.333678+00	\N	4	Lillie72	1998	406-680-0076	Marcia.Kris@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Mrs.	I	Dr.	sn	-82.7954	136.6618	253-558-1439	11	inactive
132	2024-11-21 09:42:05.854652+00	2024-11-22 02:08:04.266238+00	\N	4	nh2	2000	089686859	nh2@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	06	062	01945	jsnsn	10.486349257913131	106.49945164829643	1730684292510	400	active
12	2024-11-07 09:36:04.809638+00	2024-11-07 09:36:04.809638+00	\N	4	Kathryne.Dicki38	1998	858-419-0834	Modesto_Kunze@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Ms.	MD	Mr.	fil	-0.6572	-6.1115	315-726-7896	12	inactive
129	2024-11-21 09:34:18.678002+00	2024-11-21 09:34:18.678002+00	\N	4	lnh2	2000	0968238468	hanle2@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	06	061	01897	hẻm sông	10.757416240467604	107.14947551216707	1731980292510	398	inactive
56	2024-11-20 08:54:17.041266+00	2024-11-22 02:55:24.053027+00	\N	4	zdd	1999	0784965123456	ngfjf@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	06	058	01837	aa	10.218108881751977	107.13356720259172	1730684292510	258	active
13	2024-11-07 09:36:46.428314+00	2024-11-07 09:36:46.428314+00	\N	4	Katrina.Prohaska8	1998	883-772-3445	Nicole67@yahoo.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Ms.	MD	Mr.	nb	17.7260	-78.8623	931-811-8705	13	active
14	2024-11-07 09:36:54.05736+00	2024-11-07 09:36:54.05736+00	\N	4	Paolo.Hessel	2000	761-983-2657	Jeremie_Herzog@hotmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Mr.	IV	Mr.	cs	-60.0666	-173.6583	715-586-7011	14	active
15	2024-11-07 09:36:57.043794+00	2024-11-07 09:36:57.043794+00	\N	4	Ardella_Runolfsdottir	1960	356-488-7990	Name.Jaskolski40@hotmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Miss	V	Mr.	bn	-74.5095	-156.0290	727-774-2931	15	active
16	2024-11-07 09:37:00.177391+00	2024-11-19 03:33:11.354073+00	\N	4	Francisco7	1960	264-347-1178	Nelle71@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Mr.	Jr.	Dr.	ru	78.3835	-115.2591	775-883-0144	16	active
17	2024-11-07 09:37:02.881334+00	2024-11-07 09:37:02.881334+00	\N	4	Nicola.Lowe	1960	943-322-4812	Trudie.Keeling@yahoo.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Mrs.	I	Mr.	gl	-43.8446	151.3412	340-712-5480	17	active
18	2024-11-07 09:37:07.04964+00	2024-11-07 09:37:07.04964+00	\N	4	Margaretta10	1960	847-505-4218	Armando.Ryan@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Dr.	Jr.	Miss	cs	-1.5284	-165.6140	985-665-1100	18	active
19	2024-11-07 09:37:34.126849+00	2024-11-19 09:59:38.624889+00	\N	4	Ciara98	1987	732-945-6660	Dorthy82@yahoo.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Miss	MD	Ms.	ln	60.3826	-48.7627	914-784-6786	19	active
20	2024-11-07 09:37:37.849317+00	2024-11-23 02:07:50.733328+00	\N	4	Vern78	1987	360-784-2807	Mariane_OReilly@hotmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Ms.	DVM	Miss	rm	-55.9576	157.8712	799-547-7244	20	inactive
139	2024-11-22 07:51:27.345959+00	2024-11-29 02:13:57.590008+00	\N	4	nh8	2000	086355636	nh8@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732261886030169341.jpeg	http://holote.vn:8083/image-storage/IMG1732261886030173887.jpeg	06	063	01981	memrmr	10.82247561888348	106.29300184763007	1731980292510	414	active
142	2024-11-22 08:08:09.556146+00	2024-11-22 08:10:12.902608+00	\N	4	nh11	2000	05685865396	nh11@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732262888199011815.jpeg	http://holote.vn:8083/image-storage/IMG1732262888199007948.jpeg	19	171	05773	hjjj	10.781593834114817	106.6244374510958	1732066692510	416	active
143	2024-11-22 08:19:12.277291+00	2024-11-22 08:23:48.796677+00	\N	4	nh12	2000	0963256856	nh12@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732263550932528214.jpeg	http://holote.vn:8083/image-storage/IMG1732263550932527878.jpeg	02	026	00730	3dchu	10.650608728072891	106.82065627609018	1732066692510	417	active
133	2024-11-22 01:25:07.74466+00	2024-11-22 01:25:07.74466+00	\N	4	bao	2001	09090909	bao@gmial.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732238706067987671.jpeg	http://holote.vn:8083/image-storage/IMG1732238706063937651.jpeg	01	002	00037	26	10.855085677765224	106.60514365929244	1732269630421	331	inactive
130	2024-11-21 09:38:58.893862+00	2024-11-21 09:38:58.893862+00	\N	4	a	2001	11001011111	abc@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	01	003	00094	so 20	11.093069679120527	106.33815963826558	1732212859491	256	inactive
144	2024-11-22 08:21:40.318675+00	2024-11-22 08:23:52.836586+00	\N	4	nh13	2000	096538568	nh13@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732263699005262266.jpeg	http://holote.vn:8083/image-storage/IMG1732263699005260402.jpeg	11	097	03190	jxjjcdjdn	10.153448598104326	106.34539405256317	1731980292510	418	active
141	2024-11-22 08:05:51.548658+00	2024-11-22 08:10:08.327649+00	\N	4	nh10	2000	0963254286	nh10@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732262750166099705.jpeg	http://holote.vn:8083/image-storage/IMG1732262750166099505.jpeg	04	047	01462	nsnxnx	10.793253365271509	107.00753272440245	1731980292510	415	active
128	2024-11-21 09:30:42.097252+00	2024-11-21 09:30:42.097252+00	\N	4	lnh1	2000	0856275392	hanle1@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	56	571	22492	hẻm 33	10.918767141009289	106.57992619459088	1732066692510	397	inactive
140	2024-11-22 07:52:39.914429+00	2024-11-22 07:54:08.175717+00	\N	4	nh9	1999	0896538866	nh9@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732261958603563537.jpeg	http://holote.vn:8083/image-storage/IMG1732261958603563666.jpeg	06	063	01969	ekfmfn	10.576449913552889	106.28462678007675	1732153092510	413	active
138	2024-11-22 07:29:30.803075+00	2024-11-22 07:33:42.22767+00	\N	4	nh6	2000	0856865685	nh6@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732260569186520010.jpeg	http://holote.vn:8083/image-storage/IMG1732260569186520283.jpeg	45	467	19564	jjjk	10.200070861857716	106.73172691124019	1731980292510	412	active
21	2024-11-07 09:37:40.802475+00	2024-11-07 09:37:40.802475+00	\N	4	Bradford_Wuckert34	1987	465-728-8135	Dahlia_Ratke26@yahoo.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Ms.	DDS	Miss	so	-41.7462	71.2765	801-541-3403	21	active
147	2024-11-22 09:32:46.536005+00	2024-11-22 09:40:05.865897+00	\N	4	nh16	2000	0968696568	nh16@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732267965258652370.jpeg	http://holote.vn:8083/image-storage/IMG1732267965258639995.jpeg	08	074	02380	hjjjh	11.102663778540487	106.34064589165595	1731980292510	421	active
146	2024-11-22 09:20:26.600513+00	2024-11-22 09:21:27.803198+00	\N	4	nh15	2000	096838655	nh15@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732267225222355607.jpeg	http://holote.vn:8083/image-storage/IMG1732267225222367963.jpeg	02	028	00826	zxcfj	10.690747069181846	106.83378582704354	1732066692510	420	active
145	2024-11-22 09:16:10.098107+00	2024-11-22 09:21:22.529643+00	\N	4	nh14	2000	0968686855	nh14@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732266968780348651.jpeg	http://holote.vn:8083/image-storage/IMG1732266968780327835.jpeg	64	633	23956	edff	10.4534625215199	107.03883400297755	1731461892510	419	active
150	2024-11-23 04:01:52.652687+00	2024-11-23 04:04:45.091369+00	\N	4	hn1	2000	0966865386	hn1@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732334511156468142.jpeg	http://holote.vn:8083/image-storage/IMG1732334511156468250.jpeg	10	084	02803	bbji GG kih	10.175505495227787	107.23881645550769	1732153092510	426	active
148	2024-11-22 09:35:37.072925+00	2024-11-22 09:40:10.260763+00	\N	4	nh17	1999	0968384684	nh17@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732268135794742201.jpeg	http://holote.vn:8083/image-storage/IMG1732268135794741214.jpeg	08	075	02440	ssdndjej	10.976110899479737	106.26408650036609	1732066692510	422	active
149	2024-11-23 03:58:26.814632+00	2024-11-23 03:58:26.814632+00	\N	4	nh20	2000	0896869686	nh20@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732334305097776457.jpeg	http://holote.vn:8083/image-storage/IMG1732334305097778221.jpeg	10	083	02758	hdjfnfjdj	10.623234918493019	106.92264132275687	1732239492510	425	inactive
137	2024-11-22 06:58:07.780008+00	2024-11-25 03:12:17.604757+00	\N	4	nh4	2000	0968523485	40h3658	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732258686523057758.jpeg	http://holote.vn:8083/image-storage/IMG1732258686523093258.jpeg	02	027	00775	hjsjs	11.113004325887855	106.5362667171486	1732153092510	403	inactive
22	2024-11-07 09:37:43.573317+00	2024-11-07 09:37:43.573317+00	\N	4	Waino0	1987	413-659-4894	Rosalinda.Jacobs56@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Mrs.	IV	Mr.	om	-26.5173	-6.9493	781-926-9664	22	active
23	2024-11-07 09:37:47.674173+00	2024-11-07 09:37:47.674173+00	\N	4	Beatrice87	1987	303-257-8263	Payton_Walker@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Mr.	V	Ms.	hmn	55.0107	-49.5739	499-361-6192	23	active
24	2024-11-07 09:37:50.993351+00	2024-11-07 09:37:50.993351+00	\N	4	Daniela.Miller48	2000	625-302-6941	Tobin_Klocko@yahoo.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Mrs.	DDS	Ms.	tk	49.4417	173.7391	541-744-4963	24	active
25	2024-11-15 04:32:03.585335+00	2024-11-15 04:32:03.585335+00	\N	4	Buford18	2001	706-915-2086	Krystel_Glover@yahoo.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Dr.	DVM	Miss	ar	-14.8952	157.6045	307-791-7994	33	active
26	2024-11-15 08:20:29.623709+00	2024-11-15 08:20:29.623709+00	\N	4	Brady.Nienow	1999	619-924-87073	Valentine_Ondricka51@hotmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Ms.	Jr.	Miss	tr	-77.3425	151.4532	626-607-24560	42	active
27	2024-11-15 08:26:57.17161+00	2024-11-15 08:26:57.17161+00	\N	4	Brady.Nienow	1986	619-924-87071	ValentineOndricka51@hotmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Ms.	Jr.	Miss	tr	-77.3425	151.4532	626-607-2456	43	active
157	2024-11-25 03:50:05.174657+00	2024-11-25 03:50:05.174657+00	\N	4	bAO	2001	098765473	BAo@gmail.com	$2a$10$sztQap1H8q55fKnPqDMYROqs7xriVUU2Qs0cummaOjDyPzc4z96ne	http://holote.vn:8083/image-storage/IMG1732506604124020511.jpeg	http://holote.vn:8083/image-storage/IMG1732506604124008353.jpeg	01	002	00046	12	10.880857844337624	107.04121433131594	1732537691051	427	inactive
42	2024-11-15 08:30:03.069306+00	2024-11-15 08:30:03.069306+00	\N	4	Brady.Nienow1	1977	619-924-8709	ValentineOndricka511@hotmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Ms.	Jr.	Miss	tr	-77.3425	151.4532	626-607-2456	44	active
43	2024-11-15 08:33:19.621332+00	2024-11-15 08:33:19.621332+00	\N	4	Brady.Nienow2	1999	619-924-87072	ValentineOndricka52@hotmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Ms.	Jr.	Miss	tr	-77.3425	151.4532	626-607-2456	45	active
44	2024-11-15 08:56:44.451444+00	2024-11-20 08:47:10.466901+00	\N	4	 John Doe7	1999	 0534567487	johndoe7@example.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	01	 001	00001	123 Pham Van Dong	21.028511	105.804817	1548053000000	47	inactive
45	2024-11-19 09:41:57.894369+00	2024-11-19 09:41:57.894369+00	\N	4	han nha	1989	0869634878	hannha@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	64	00004	00001	sn	-85.7393	114.5577	1582995600000	247	inactive
167	2024-11-25 10:02:08.773855+00	2024-11-25 10:06:19.601994+00	\N	4	nh26	2000	0968538685	nh26@gmail.com	$2a$10$oHPnYCOPhqc/9E/1ouM9Y.ASM9sfKk9GXq3IE.t/qe8CBoIHtkh92	http://holote.vn:8083/image-storage/IMG1732528927526281953.jpeg	http://holote.vn:8083/image-storage/IMG1732528927526277202.jpeg	04	043	01330	sndjfjrj	10.907985883536979	106.93822196585016	1731980292510	431	inactive
61	2024-11-21 06:37:32.345394+00	2024-11-21 06:39:57.786401+00	\N	4	goood1	1980	843-809-0990	good@hkn	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Dr.	II	Mrs.	sm	53.5540	77.8893	362-752-4827	265	active
164	2024-11-25 04:21:43.746669+00	2024-11-25 07:55:00.612621+00	\N	4	nh23	2000	0854254256	nh23@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732508502744217835.jpeg	http://holote.vn:8083/image-storage/IMG1732508502744164634.jpeg	10	085	02854	smzkdk	10.993246652729564	107.25178325501057	1732325892510	428	active
169	2024-11-26 01:57:48.451129+00	2024-11-26 01:57:48.451129+00	\N	4	ab	2001	0869307220	ba12o@gamil.com	$2a$10$XitDDacLGYMxCXSCpvzng.UK2JcSurhMk0VVqviIOiBIk0AobVGQ2	http://holote.vn:8083/image-storage/IMG1732586267219205708.jpeg	http://holote.vn:8083/image-storage/IMG1732586267219252153.jpeg	02	031	00997	12 an xuong	10.27462355970154	107.12083480332701	1732498692510	402	inactive
171	2024-11-26 01:59:26.815398+00	2024-11-26 01:59:26.815398+00	\N	4	An la	2001	0987658746	bao12111@gmail.com	$2a$10$qZA.PrPkUUyXRSpnyKNiv.Q/wdGO3NpExGUC./KMi2wQ8krmysI/e	http://holote.vn:8083/image-storage/IMG1732586365714419583.jpeg	http://holote.vn:8083/image-storage/IMG1732586365714410324.jpeg	02	029	00886	12 an l	10.309753905650084	106.58020795703045	1731893892510	424	inactive
165	2024-11-25 04:24:02.787634+00	2024-11-25 07:55:07.251899+00	\N	4	nh24	2000	0965965664	nh24@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732508641569636676.jpeg	http://holote.vn:8083/image-storage/IMG1732508641569628571.jpeg	08	072	02230	xndnn	10.267376178388874	106.64311619564931	1732325892510	429	active
163	2024-11-25 04:02:09.683532+00	2024-11-25 04:04:03.756756+00	\N	4	nh22	2000	0968536526	nh22@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732507328465098922.jpeg	http://holote.vn:8083/image-storage/IMG1732507328465099117.jpeg	01	002	00040	hhjghnj	10.213145550088408	106.47271600384963	1732325892510	423	active
166	2024-11-25 08:04:07.096637+00	2024-11-25 08:05:13.146905+00	\N	4	nh25	2000	0896535568	nh25@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732521846053963262.jpeg	http://holote.vn:8083/image-storage/IMG1732521846053958956.jpeg	04	047	01462	bjjhbj	10.35916951943987	107.23011087593238	1732153092510	430	active
172	2024-11-26 03:51:06.91594+00	2024-11-26 06:27:47.377034+00	\N	4	nh27	2000	0965832569	nh27@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732593065652039114.jpeg	http://holote.vn:8083/image-storage/IMG1732593065651984099.jpeg	52	549	21922	djskdnd	10.885701638487564	106.86445068096138	1732325892510	432	active
175	2024-11-26 07:43:23.792899+00	2024-11-26 07:53:20.425236+00	\N	4	nh30	2000	089683986	nh30@gmail.com	$2a$10$UTS5CM.59331ogUYnanMxuNWlP8/M5CV.gD3Dk1Sc5VbMEYZGZLW6	http://holote.vn:8083/image-storage/IMG1732607002590764684.jpeg	http://holote.vn:8083/image-storage/IMG1732607002590764676.jpeg	64	623	23617	hai bà trưng	10.54845505314842	106.57489033536878	1731375492510	435	active
173	2024-11-26 06:25:42.073843+00	2024-11-26 06:27:52.324756+00	\N	4	nh28	2000	0896535742	nh28@gmail.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732602340679470746.jpeg	http://holote.vn:8083/image-storage/IMG1732602340679473551.jpeg	02	029	00883	jsdbdhie	11.11608397964011	106.83948557232708	1732239492510	433	active
174	2024-11-26 06:36:04.165305+00	2024-11-26 06:36:04.165305+00	\N	4	nh29	2000	0856325685	nh29@gmail.com	$2a$10$YvEce8hKm346u4rnB6nDqOtQa1kzy9rTKXcxsxQaVCDdjoBeOkPaW	http://holote.vn:8083/image-storage/IMG1732602962937918344.jpeg	http://holote.vn:8083/image-storage/IMG1732602962937918466.jpeg	08	072	02230	mjshjsajxb	11.12832067582033	106.96669733963587	1732239492510	434	inactive
176	2024-11-26 07:48:54.813721+00	2024-11-26 07:53:24.724244+00	\N	4	nh31	2000	09685385864	nh31@gmail.com	$2a$10$45llNhI55D1sYJsC9f5D5e83SlhGLnC/gFAvkCipdiZMM7222DMWS	http://holote.vn:8083/image-storage/IMG1732607333539616710.jpeg	http://holote.vn:8083/image-storage/IMG1732607333539702117.jpeg	10	085	02851	vébjsjsj	10.610572270076515	106.72553750504042	1731634692510	436	active
178	2024-11-27 03:26:09.418581+00	2024-11-27 03:26:09.418581+00	\N	4	bao	2001	0987652671	bao1234@gmail.com	$2a$10$.loq8TpB/6eDOKFKRXXU2eigG5ilGe7D8vskPi3HMjb4KVvT2DYYW	http://holote.vn:8083/image-storage/IMG1732677930432836009.jpeg	http://holote.vn:8083/image-storage/IMG1732677930432858767.jpeg	01	003	00103	so 12	11.063320995238524	106.59239295174646	1732708643054	401	inactive
94	2024-11-21 06:41:18.168427+00	2024-11-21 06:42:01.077972+00	\N	4	goood2	2000	990-522-8169	good2@hkn	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Ms.	Jr.	Mr.	oc	-71.9536	-161.4605	968-397-8344	298	active
127	2024-11-21 08:55:04.092125+00	2024-11-21 08:55:04.092125+00	\N	4	Myriam16	2003	981-380-7994	Coralie6@yahoo.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://placeimg.com/640/480	http://placeimg.com/640/480	Mrs.	III	Ms.	ar	-72.3009	-51.5661	615-261-5046	25	inactive
134	2024-11-22 05:02:15.228086+00	2024-11-22 05:02:15.228086+00	\N	4	a	2001	1909091	bao@gamil.com	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732251734005773808.jpeg	http://holote.vn:8083/image-storage/IMG1732251734005742197.jpeg	01	002	00043	12	10.70873372805456	106.93406993892995	1732282768916	263	inactive
135	2024-11-22 06:49:10.613384+00	2024-11-22 06:49:10.613384+00	\N	4	a	1999	1111111	as	$2a$10$tCaF14bo2KpLjmSaikld6.le9hgYuQeA8Usagyp9aQSCTqjb4gU7W	http://holote.vn:8083/image-storage/IMG1732258149360221003.jpeg	http://holote.vn:8083/image-storage/IMG1732258149360367426.jpeg	01	004	00121	12	11.0124815551427	106.51097957802143	1732289238071	364	inactive
182	2024-12-02 04:05:20.819017+00	2024-12-02 04:05:20.819017+00	\N	4	nh33	2000	0968536466	nh33@gmail.com	$2a$10$rHUzwAcOewFmNR2SKcCHruPtpDmXZTNFSSKlDspboYXDV2ia9r9KK	http://holote.vn:8083/image-storage/IMG1733112318705416769.jpeg	http://holote.vn:8083/image-storage/IMG1733112318705416954.jpeg	44	457	19261	cbxjxj	10.219881651753292	106.42453487455442	1731375492510	442	inactive
57	2024-11-20 09:03:34.922807+00	2024-11-28 06:07:15.828804+00	\N	4	bao moi	2001	0987654372	bao@gmail.com	$2a$10$iawoRxBefud3HessM82C7ObtUl4/73bHfCU50ekqH4FDQCWSBRFPe	http://placeimg.com/640/480	http://placeimg.com/640/480	02	024	00691	ab	10.294151494150622	107.1477996488043	1731980292510	259	active
162	2024-11-25 03:58:50.470721+00	2024-11-25 08:00:00.603591+00	\N	4	nh21	2000	0968383886	nh21@gmail.com	$2a$10$iawoRxBefud3HessM82C7ObtUl4/73bHfCU50ekqH4FDQCWSBRFPe	http://holote.vn:8083/image-storage/IMG1732507129467613598.jpeg	http://holote.vn:8083/image-storage/IMG1732507129467604779.jpeg	01	005	00167	jcjdndnd	10.82427316115052	107.04896802915253	1732066692510	48	active
179	2024-11-30 21:59:20.99189+00	2024-11-30 21:59:20.99189+00	\N	4	baoko	2001	0913893832	baoko@gmail.com	$2a$10$TYnZk0N52F6eSfRRQiRDa.NKBFVZdbLB9r1QArnxYH0jmOr1RaUXi	http://holote.vn:8083/image-storage/IMG1733003958861630136.jpeg	http://holote.vn:8083/image-storage/IMG1733003958861630089.jpeg	02	028	00832	ko a	10.506101572253383	106.65380698917406	1733035036417	439	inactive
180	2024-11-30 22:09:35.204852+00	2024-12-02 03:36:16.385642+00	\N	4	bao test	2001	0928943211	fee@gmail.com	$2a$10$wsQvXusDnlSfbVanRn/0puFoRjoLkLNp4YFlRTCIy3vJRw6ns67eK	http://holote.vn:8083/image-storage/IMG1733004573304917735.jpeg	http://holote.vn:8083/image-storage/IMG1733004573304912040.jpeg	01	003	00100	so 12	10.711779015944535	106.36043020592847	1732930692510	440	active
181	2024-12-02 04:03:58.737203+00	2024-12-02 04:03:58.737203+00	\N	4	nh32	2000	096856869	nh32@gmail.com	$2a$10$z8InPoa1R0A1vsihkhpOxO7fI4AN4yTsGnymbDBRfq8.fmue/3cHO	http://holote.vn:8083/image-storage/IMG1733112236579611775.jpeg	http://holote.vn:8083/image-storage/IMG1733112236579611728.jpeg	10	085	02851	bdjssj	10.385614970765499	106.61859974125304	1732066692510	441	inactive
\.


--
-- Data for Name: driving_car; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.driving_car (id, created_at, updated_at, deleted_at, owner_car_id, driving_name, driving_license, driving_address, driving_phone, email, password_driving, media_license_front_id, media_license_back_id, province, district, ward, device_token, driving_license_front, driving_license_back, year_of_exp) FROM stdin;
3	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00	\N	5	Nguyen Van C	59H-21313	Ha Huy Lam	0123456783	nguyevanc@gmail.com	$2a$10$rLVNRHs7twdfqK5BpJ.WYupr8wRA0QMMAMn9r1B99CXCHUZ3MPSAy	\N	\N	\N	\N	\N	\N	\N	\N	\N
1	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00	\N	5	Nguyen Van A	59H-21311	Ha Huy Tap	0123456782	nguyevana@gmail.com	$2a$10$rLVNRHs7twdfqK5BpJ.WYupr8wRA0QMMAMn9r1B99CXCHUZ3MPSAy	\N	\N	\N	\N	\N	\N	\N	\N	\N
6	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00	\N	5	BaoB	50H-09557	Ha Huy Lam	0123456785	baoB@gmail.com	$2a$10$tZJoYyAXH.W.ix9ESkf6wOBiV9530px.ax7WWxIvcwflkKvZiUZ16	\N	\N	\N	\N	\N	\N	\N	\N	\N
5	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00	\N	5	BaoA	50H-17020	Ha Huy Lam	0123456780	baoA@gmail.com	$2a$10$rLVNRHs7twdfqK5BpJ.WYupr8wRA0QMMAMn9r1B99CXCHUZ3MPSAy	\N	\N	\N	\N	\N	\N	\N	\N	\N
4	2024-04-21 08:16:42.537082+00	2024-04-21 08:16:42.323369+00	\N	5	Bao	50H-17057	Ha Huy Lam	0123456787	bao@gmail.com	$2a$10$rLVNRHs7twdfqK5BpJ.WYupr8wRA0QMMAMn9r1B99CXCHUZ3MPSAy	\N	\N	\N	\N	\N	\N	\N	\N	\N
72	2024-07-21 09:09:53.962634+00	2024-07-21 09:14:55.840234+00	\N	5	Miss Lynda Ratke	59-213141	515 Jeffry Pine	814-829-4328	Sabrina.Heaney98@hotmail.com	$2a$10$8ow2k1vRrqLF5.u4ZG80e.gUiJTkiZ8OyASCdK304NGmIogc1SGRK	\N	\N	\N	\N	\N	\N	\N	\N	\N
46	2024-05-14 06:55:02.712044+00	2024-05-14 06:55:02.712044+00	\N	5	Nguyen Van E	59H-21314	Ha Huy Tap	09111222334	nguyevane@gmail.com	$2a$10$8ow2k1vRrqLF5.u4ZG80e.gUiJTkiZ8OyASCdK304NGmIogc1SGRK	\N	\N	\N	\N	\N	\N	\N	\N	\N
70	2024-07-21 02:56:16.613941+00	2024-07-21 09:09:46.416473+00	\N	5	Roderick Stiedemann I	59H-21312	423 Herman Garden	561-355-5930	Spencer66@gmail.com	$2a$10$8ow2k1vRrqLF5.u4ZG80e.gUiJTkiZ8OyASCdK304NGmIogc1SGRK	\N	\N	\N	\N	\N	\N	\N	\N	\N
83	2024-08-29 10:17:17.525443+00	2024-08-29 10:17:17.525443+00	\N	5	Katie Pagac	50H-18499	yo	934-757-3996	Felipa_Upton@hotmail.com	$2a$10$8ow2k1vRrqLF5.u4ZG80e.gUiJTkiZ8OyASCdK304NGmIogc1SGRK	11	13	Mr.	Ms.	Mr.	\N	\N	\N	\N
\.


--
-- Data for Name: formulas; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.formulas (id, created_at, updated_at, deleted_at, owner_id, name, description, owner_formula) FROM stdin;
3	2024-11-12 10:29:40.632614+00	2024-11-12 10:29:40.632614+00	\N	4	công thức mặc định	\N	FOR1,OPERS1,FOR2,OPERS1,FOR3
\.


--
-- Data for Name: internal_customer; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.internal_customer (id, created_at, updated_at, deleted_at, customer_name, email, phone_number, company_name, tax_code, description) FROM stdin;
2	2024-08-02 10:04:06.098835+00	2024-08-27 16:14:27.61549+00	\N	Brian Bartoletti	Vada68@hotmail.com	914-433-7727	Johnson, Hintz and Balistreri	320-961-1502	\N
3	2024-08-02 10:10:53.611938+00	2024-08-27 16:16:03.183246+00	\N	Gerald Bernhard	Era_Braun26@hotmail.com	281-589-3497	Bode - Walsh	390-404-0116	\N
45	2024-09-08 12:41:56.878872+00	2024-09-08 12:41:56.878872+00	\N	Blanche Weimann	Garett_Leuschke71@yahoo.com	948-889-7952	Ledner, Metz and Gaylord	587-734-4979	description
46	2024-09-08 22:43:11.888036+00	2024-09-08 22:43:11.888036+00	\N	Heather Sipes	Aileen.Miller81@yahoo.com	957-901-8921	Koelpin - Hane	672-381-3845	description
4	2024-08-02 10:14:20.619593+00	2024-08-02 10:14:20.619593+00	\N	Terry Skiles PhD	Fanny_Runolfsdottir@hotmail.com	541-255-0798	Reilly, Lebsack and Bashirian	390-123-0116	\N
8	2024-08-02 10:35:11.931492+00	2024-08-02 10:35:11.931492+00	\N	Gerald Donnelly	Reginald_Aufderhar90@hotmail.com	271-245-8302	Altenwerth Inc	390-115-0116	\N
47	2024-09-08 22:45:08.862879+00	2024-09-08 22:45:08.862879+00	\N	vs	121ss2@gmail.com	0987654321	Gaylord - Hane	123-456-7893	1111
5	2024-08-02 10:15:49.826648+00	2024-08-02 10:15:49.826648+00	\N	Doug Stiedemann	Emily2@hotmail.com	889-316-5174	Gottlieb - Kovacek	390-112-0116	\N
7	2024-08-02 10:28:04.592795+00	2024-08-02 10:28:04.592795+00	\N	Martha Hilpert	Judy_Kilback22@hotmail.com	526-829-2008	Toy - Bayer	390-114-0116	\N
6	2024-08-02 10:22:00.224799+00	2024-08-02 10:22:00.224799+00	\N	Lorena Jacobi	Leonardo.Fahey48@yahoo.com	777-639-5697	Kris, West and Quigley	390-113-0116	\N
9	2024-08-07 06:54:19.199862+00	2024-08-07 06:54:19.199862+00	\N	Tiffany Lang	Ova.Zulauf95@gmail.com	726-960-9844	Altenwerth Bayer	390-116-0116	\N
1	2024-08-02 09:27:33.351939+00	2024-08-02 09:27:33.351939+00	\N	Julie Feest	Wava9@yahoo.com	653-656-2309	Botsford and Sons	320-961-1234	\N
44	2024-09-04 02:42:46.258618+00	2024-09-04 02:42:46.258618+00	\N	Iris Morar	Edison.Koss@hotmail.com	304-771-6007	Murazik - Corkery	587-123-4979	ASXCCFFGGG
48	2024-09-08 22:46:09.79722+00	2024-09-08 22:46:09.79722+00	\N	1212	1212@gmail.com	1212121212	ds2 Bode - Walsh	111-222-1112	1111
43	2024-08-24 02:36:30.266046+00	2024-08-24 02:36:30.266046+00	\N	Gregory Cartwright	Laura47@hotmail.com	859-592-8233	Hayes and Sons	123-381-3845	description
10	2024-08-07 06:59:23.874706+00	2024-08-07 07:03:52.370134+00	\N	Miriam Swaniawski	Sterling13@yahoo.com	772-508-5961	Harvey and Sons	123-112-3845	\N
49	2024-09-10 04:12:55.223788+00	2024-09-10 04:12:55.223788+00	\N	Bong	freedomv27@gmail.com	0988876543	Hoa Kien Nhan	98765432997	\N
50	2024-09-11 03:05:35.732802+00	2024-09-11 03:05:35.732802+00	\N	NgoiSao	ngoisao@gmail.com	0987654320	ngoisaovang	098765786	\N
\.


--
-- Data for Name: internal_customer_address; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.internal_customer_address (id, created_at, updated_at, deleted_at, internal_customer_id, contact_name, address_phone_number, price_service, province, district, ward, detail_address, lat, long, is_default) FROM stdin;
1	2024-08-02 10:04:06.112236+00	2024-08-15 04:30:51.738642+00	\N	2	Brandi Gaylord	405-378-0926	126900.00	79	769	26794	76/4, 76/4 QL1A, Linh Xuân, Thủ Đức, Hồ Chí Minh, Việt Nam	10.882023811191013	106.77507815208371	t
44	2024-08-07 09:06:03.556452+00	2024-08-15 03:46:14.717009+00	\N	2	Alexander Krajcik	294-629-0329	97600.00	79	769	26815	982 Đ. Kha Vạn Cân, Linh Chiểu, thành phố Thủ Đức, Hồ Chí Minh 70000, Việt Nam	10.853404046557174	106.75474805769466	f
4	2024-08-02 10:15:49.840012+00	2024-08-15 04:30:51.637878+00	\N	5	Debbie Abshire	262-659-2424	543200.00	79	769	26812	68 Đường 18, Hiệp Bình Chánh, Thủ Đức, Hồ Chí Minh 71315, Việt Nam	10.824793150776458	106.71910477502443	f
52	2024-09-08 22:46:09.806588+00	2024-09-08 22:46:09.806588+00	\N	48	1sad1	1212121212	121200.00	79	769	26824	20 Bác Ái, Bình Thọ, Thủ Đức, Hồ Chí Minh, Việt Nam	10.846470818052975	106.76660887655218	f
10	2024-08-07 06:54:19.215426+00	2024-08-07 06:54:19.215426+00	\N	9	Troy Kovacek	427-589-6036	412500.00	79	769	26827	96 Đ. Số 3, Trường Thọ, Thủ Đức, Hồ Chí Minh, Việt Nam	10.83437278339671	106.75604507660363	f
6	2024-08-02 10:28:04.607456+00	2024-08-02 10:28:04.607456+00	\N	7	Clifford Kulas	599-365-8773	821500.00	79	769	26818	11/6 Đ. số 5, khu phố 3, Thủ Đức, Hồ Chí Minh 700000, Việt Nam	10.856291486212898	106.75347156918602	f
48	2024-09-04 02:42:46.284909+00	2024-09-04 02:42:46.284909+00	\N	44	Denise Feest	745-983-9885	93000.00	79	769	26842	15 Đ Làng Tăng Phú, Tăng Nhơn Phú A, Quận 9, Hồ Chí Minh, Việt Nam	10.840422627176864	106.79720804571203	f
9	2024-08-05 04:37:53.793187+00	2024-08-15 03:46:14.717009+00	\N	2	Karl Marvin	422-476-4896	123400.00	79	769	26797	111b Ng. Chí Quốc, Bình Chiểu, Thủ Đức, Hồ Chí Minh, Việt Nam	10.87656735809664	106.7261688364827	f
50	2024-09-08 22:43:11.898519+00	2024-09-08 22:43:11.898519+00	\N	46	Teri Kertzmann	817-491-0349	653200.00	79	769	26836	153 Đ. Nam Cao, Phường Tân Phú, Thủ Đức, Hồ Chí Minh, Việt Nam	10.856181213947007	106.80284332269044	f
2	2024-08-02 10:10:53.624555+00	2024-08-02 10:10:53.624555+00	\N	3	Amy Lynch I	747-474-6558	654000.00	79	769	26839	123-125 Lê Văn Việt, P, Quận 9, Hồ Chí Minh 700000, Việt Nam	10.846360611260952	106.77828362793493	f
7	2024-08-02 10:35:11.944974+00	2024-08-02 10:35:11.944974+00	\N	8	Paulette Kunze	591-361-2554	129000.00	79	769	26854	1792 Đ. Nguyễn Duy Trinh, Trường Thạnh, Quận 9, Hồ Chí Minh 70000, Việt Nam	10.813595884558357	106.83404429396899	f
5	2024-08-02 10:22:00.238409+00	2024-08-02 10:22:00.238409+00	\N	6	Sherri Collins	307-780-2050	547000.00	79	769	27112	14 đường 100, Phường Thạnh Mỹ Lợi, Thủ Đức, Hồ Chí Minh 71114, Việt Nam	10.770024727695503	106.76844721043359	f
11	2024-08-07 06:59:23.880638+00	2024-08-07 06:59:23.880638+00	\N	10	Martin Torp	276-907-0678	541200.00	79	769	26806	14 Bình Phú, Tam Phú, Thủ Đức, Hồ Chí Minh 700000, Việt Nam	10.85461922755536	106.73908242443039	f
8	2024-08-05 03:27:07.449343+00	2024-08-15 03:46:14.717009+00	\N	2	Mr. Shelley Gleichner	757-928-4065	98000.00	79	769	26821	Khách Sạn Vũ Với, 35 Đ. Số 40, Linh Đông, Thủ Đức, Hồ Chí Minh, Việt Nam	10.84805591446394	106.75166852544902	f
49	2024-09-08 12:41:56.903024+00	2024-09-08 12:41:56.903024+00	\N	45	Max Hackett	907-487-8682	349000.00	79	769	26857	336, Long Phước, Quận 9, Hồ Chí Minh, Việt Nam	10.806998351924051	106.85930926867326	f
51	2024-09-08 22:45:08.871194+00	2024-09-08 22:45:08.871194+00	\N	47	1sad	0987654321	128900.00	79	769	26833	309 Nguyễn Văn Tăng, Long Thạnh Mỹ, Quận 9, Hồ Chí Minh, Việt Nam	10.841598146839184	106.8230836173034	f
45	2024-08-15 03:44:44.690724+00	2024-08-15 03:46:14.717009+00	\N	2	Doug Dicki	876-796-8264	124500.00	79	769	26803	khu phố 4, Tam Bình, Thủ Đức, Hồ Chí Minh, Việt Nam	10.867438933062349	106.73375105479278	f
47	2024-08-24 02:36:30.290156+00	2024-08-24 02:36:30.290156+00	\N	43	Juana Bode	741-285-6923	960123.00	79	769	26830	65 Đường A, Long Bình, Quận 9, Hồ Chí Minh, Việt Nam	10.890932590869472	106.8283156848659	f
46	2024-08-15 03:45:38.695072+00	2024-08-15 03:45:38.695072+00	\N	2	Whitney Hand	981-943-9972	100000.00	79	769	26809	8 Đường 17 kp3, Hiệp Bình Phước, Thủ Đức, Hồ Chí Minh, Việt Nam	10.860663433594931	106.72332983256399	t
3	2024-08-02 10:14:20.630563+00	2024-08-15 04:25:51.12385+00	\N	4	Barry Lehner	333-479-2435	567800.00	79	769	26800	VQ5J+W7M, Phường Linh Trung, Thủ Đức, Hồ Chí Minh, Việt Nam	10.859979039575292	106.78070259851098	t
53	2024-09-10 04:12:55.244507+00	2024-09-10 04:12:55.244507+00	\N	49	nguyen an	09876543219	90000.00	01	250	08973	duong so 7	13.8127	-7.1436	f
54	2024-09-11 03:05:35.7438+00	2024-09-11 03:05:35.7438+00	\N	50	NguyenA	0987654322	129000.00	27	258	09199	so9	13.8127	-7.1436	f
\.


--
-- Data for Name: internal_customer_good_type; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.internal_customer_good_type (internal_good_type_id, internal_customer_id, id, created_at, updated_at, deleted_at) FROM stdin;
1	9	15	2024-08-07 06:54:19.207817+00	2024-08-07 06:54:19.207817+00	\N
1	10	16	2024-08-07 06:59:23.877722+00	2024-08-07 06:59:23.877722+00	\N
1	2	17	2024-08-07 07:03:02.651155+00	2024-08-07 07:03:02.651155+00	\N
2	2	18	2024-08-07 07:03:02.65446+00	2024-08-07 07:03:02.65446+00	\N
2	10	19	2024-08-07 07:03:10.012111+00	2024-08-07 07:03:52.500762+00	2024-08-07 07:03:52.500569+00
1	43	49	2024-08-24 02:36:30.279416+00	2024-08-24 02:36:30.279416+00	\N
2	43	50	2024-08-24 02:36:30.287398+00	2024-08-24 02:36:30.287398+00	\N
1	44	51	2024-09-04 02:42:46.273281+00	2024-09-04 02:42:46.273281+00	\N
2	44	52	2024-09-04 02:42:46.282355+00	2024-09-04 02:42:46.282355+00	\N
1	45	53	2024-09-08 12:41:56.891417+00	2024-09-08 12:41:56.891417+00	\N
2	45	54	2024-09-08 12:41:56.900281+00	2024-09-08 12:41:56.900281+00	\N
1	46	55	2024-09-08 22:43:11.892061+00	2024-09-08 22:43:11.892061+00	\N
2	46	56	2024-09-08 22:43:11.895285+00	2024-09-08 22:43:11.895285+00	\N
2	47	57	2024-09-08 22:45:08.865745+00	2024-09-08 22:45:08.865745+00	\N
1	47	58	2024-09-08 22:45:08.868386+00	2024-09-08 22:45:08.868386+00	\N
2	48	59	2024-09-08 22:46:09.80067+00	2024-09-08 22:46:09.80067+00	\N
1	48	60	2024-09-08 22:46:09.803677+00	2024-09-08 22:46:09.803677+00	\N
2	49	61	2024-09-10 04:12:55.235645+00	2024-09-10 04:12:55.235645+00	\N
2	50	62	2024-09-11 03:05:35.736622+00	2024-09-11 03:05:35.736622+00	\N
1	50	63	2024-09-11 03:05:35.741114+00	2024-09-11 03:05:35.741114+00	\N
\.


--
-- Data for Name: internal_good_type; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.internal_good_type (id, created_at, updated_at, deleted_at, name, description) FROM stdin;
2	2024-08-05 03:52:10.309457+00	2024-08-05 03:52:10.309457+00	\N	tro bay	\N
8	2024-09-08 18:00:44.011487+00	2024-09-08 18:00:44.011487+00	\N	nhựa dẻo 	\N
1	2024-08-01 07:31:02.701313+00	2024-09-09 03:13:44.996906+00	\N	cát	\N
6	2024-08-07 07:08:38.133484+00	2024-09-09 03:14:21.963159+00	\N	xi măng	\N
7	2024-09-08 17:57:43.221512+00	2024-09-09 03:14:40.54114+00	\N	nhựa	\N
9	2024-09-09 04:26:46.249606+00	2024-09-09 04:26:46.249606+00	\N	te	\N
10	2024-09-09 04:26:49.092484+00	2024-09-09 04:26:49.092484+00	\N	tes	\N
11	2024-09-09 04:26:51.589216+00	2024-09-09 04:26:51.589216+00	\N	tess	\N
12	2024-09-09 04:26:53.882545+00	2024-09-09 04:26:53.882545+00	\N	tesss	\N
13	2024-09-09 04:26:56.113589+00	2024-09-09 04:26:56.113589+00	\N	tessss	\N
14	2024-09-09 04:26:58.281446+00	2024-09-09 04:26:58.281446+00	\N	tesssss	\N
15	2024-09-09 04:27:00.487434+00	2024-09-09 04:27:00.487434+00	\N	tessssss	\N
16	2024-09-09 04:27:02.490962+00	2024-09-09 04:27:02.490962+00	\N	tesssssss	\N
17	2024-09-09 04:27:04.626746+00	2024-09-09 04:27:04.626746+00	\N	tessssssss	\N
18	2024-09-09 04:27:06.586697+00	2024-09-09 04:27:06.586697+00	\N	tesssssssss	\N
\.


--
-- Data for Name: internal_order_media; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.internal_order_media (id, created_at, updated_at, deleted_at, order_id, media_id, user_role_id, user_role, order_status, media_name) FROM stdin;
3	2024-08-26 03:43:59.749469+00	2024-08-26 03:43:59.749469+00	\N	1	10	5	owner	11	heyhey
4	2024-08-29 07:00:50.982563+00	2024-08-29 07:00:50.982563+00	\N	10	13	5	owner	11	hey hey hey
\.


--
-- Data for Name: internal_orders; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.internal_orders (id, created_at, updated_at, deleted_at, order_code, owner_car_id, customer_id, customer_address_id, warehouse_id, truck_id, driver_id, weight, price, vat, status, description, project_process, order_type, order_name) FROM stdin;
33	2024-09-09 16:03:30.232862+00	2024-09-12 07:11:16.79022+00	\N	0ED4SY26W89M	5	2	44	4	\N	\N	56000.00	397600.00	10.00	4	National	\N	1	\N
15	2024-08-27 04:02:44.469331+00	2024-08-29 06:11:28.892167+00	\N	9SO0OOGPSVDW	5	1	1	4	\N	\N	1000.00	739398.68	10.00	6	Human	101.10	2	Project 1
10	2024-08-16 09:44:22.05641+00	2024-08-29 07:01:24.742932+00	\N	GHKGHTYX8E73	5	1	1	4	\N	\N	56000.00	739398.68	10.00	11	Regional	\N	1	\N
9	2024-08-16 06:52:27.592305+00	2024-08-16 07:11:19.258388+00	\N	N87C11F93AI9	5	1	1	4	\N	\N	56000.00	739398.68	10.00	6	Customer	\N	1	\N
34	2024-09-09 16:03:41.074028+00	2024-09-12 07:12:00.752539+00	\N	U980K0KWXVD5	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	4	Regional	\N	1	\N
8	2024-08-16 06:18:46.333344+00	2024-08-29 07:16:29.613721+00	\N	Q2C3H8FKV1DA	5	1	1	4	\N	\N	56000.00	739398.68	10.00	12	Regional	\N	1	\N
18	2024-08-31 06:39:15.182493+00	2024-08-31 06:42:55.223651+00	2024-08-31 06:42:55.223651+00	DKB7AGD40IZG	5	1	1	4	\N	\N	10000.00	739398.68	10.00	3	Dynamic	\N	2	Project 1
22	2024-09-09 04:04:16.282032+00	2024-09-12 06:37:23.861017+00	\N	88PIUOJRAJ32	5	2	44	4	9	72	70000.00	90000.00	10.00	4	Human	\N	1	\N
23	2024-09-09 06:36:00.679606+00	2024-09-12 06:40:25.922374+00	\N	H50PAUJ8I88I	5	1	1	4	\N	\N	1000.00	739398.68	10.00	4	Investor	0.00	2	Hammes - Kunze
1	2024-08-08 09:01:55.771531+00	2024-08-26 03:44:32.078632+00	\N	C1HKIK7X2RLA	5	3	2	4	7	7	69.00	346000.00	10.00	11	Corporate	\N	1	\N
24	2024-09-09 15:20:44.81648+00	2024-09-12 06:41:48.555994+00	\N	8D1YR4FXXH6Y	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	4	\N	\N	1	\N
25	2024-09-09 15:20:54.538547+00	2024-09-12 06:42:49.79031+00	\N	CR6E98X2951X	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	4	\N	\N	1	\N
3	2024-08-08 09:06:43.600449+00	2024-08-27 10:00:51.564822+00	\N	OO8DSA04NQA9	5	3	2	4	\N	\N	56000.00	280001000.00	10.00	3	Corporate	\N	1	\N
26	2024-09-09 15:21:07.986148+00	2024-09-12 06:44:12.217531+00	\N	R9FQKXDRSNZ7	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	4	\N	\N	1	\N
17	2024-08-27 16:15:29.539228+00	2024-09-04 07:46:15.888076+00	\N	VNO1K6IPO7E1	5	2	1	4	6	6	56000.00	280001000.00	10.00	3	Global	\N	1	\N
16	2024-08-27 16:13:54.223232+00	2024-08-27 16:13:54.223232+00	\N	LKT53ZNVTX7H	5	1	1	4	\N	\N	56000.00	739398.68	10.00	2	Dynamic	\N	1	\N
2	2024-08-08 09:11:24.958383+00	2024-08-27 16:16:03.977003+00	\N	6D084O9KHNFD	5	3	2	4	4	4	56000.00	280001000.00	10.00	10	Human	\N	1	\N
27	2024-09-09 15:22:10.437705+00	2024-09-12 06:48:34.395115+00	\N	6NYHYBPF4B7V	5	2	1	4	\N	\N	1222.00	4172190.00	10.00	4	\N	\N	1	\N
28	2024-09-09 15:22:27.594301+00	2024-09-12 06:49:45.04179+00	\N	CJOWRUG0YPER	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	4	Chief	\N	1	\N
19	2024-09-09 03:57:05.256443+00	2024-09-09 08:03:14.3715+00	\N	BE8D2CHJRUPK	5	1	44	4	5	5	56000.00	397600.00	10.00	3	Lead	\N	1	\N
31	2024-09-09 15:58:39.561647+00	2024-09-12 07:09:52.456238+00	\N	TIHVZTM96F04	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	4	Regional	\N	1	\N
32	2024-09-09 16:02:57.321925+00	2024-09-12 07:11:01.606637+00	\N	TWUMHLRPZAN3	5	2	44	4	\N	\N	56000.00	397600.00	10.00	4	Central	\N	1	\N
13	2024-08-21 10:26:20.868322+00	2024-09-09 09:37:24.488773+00	\N	N77NI7UBH9ZS	5	4	1	4	4	4	69.00	346000.00	10.00	12	Customer	\N	1	\N
20	2024-09-09 04:04:16.282032+00	2024-09-09 04:47:01.404711+00	\N	12PPNOJXAJ56	5	2	44	4	8	46	56000.00	397600.00	10.00	3	Corporate	\N	1	\N
29	2024-09-09 15:22:28.654144+00	2024-09-09 15:22:28.654144+00	\N	F1B80J7FIAYI	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	2	International	\N	1	\N
30	2024-09-09 15:58:09.089777+00	2024-09-09 15:58:09.089777+00	\N	7KZXHOTE13ZR	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	2	Regional	\N	1	\N
35	2024-09-09 16:13:14.664267+00	2024-09-09 16:13:14.664267+00	\N	NTHDV4BFF4QI	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	2	Regional	\N	1	\N
36	2024-09-09 16:13:34.664443+00	2024-09-09 16:13:34.664443+00	\N	PTDEBMOHSO8O	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Global	\N	1	\N
37	2024-09-09 16:15:09.508588+00	2024-09-09 16:15:09.508588+00	\N	K70DURXI1DJS	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Internal	\N	1	\N
38	2024-09-09 16:15:10.28356+00	2024-09-09 16:15:10.28356+00	\N	8LZD0T0X06EV	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Dynamic	\N	1	\N
39	2024-09-09 16:15:11.05202+00	2024-09-09 16:15:11.05202+00	\N	VUJZDDMBI6CD	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Investor	\N	1	\N
40	2024-09-09 16:15:11.770035+00	2024-09-09 16:15:11.770035+00	\N	67ZE9D3Q3PAJ	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Legacy	\N	1	\N
41	2024-09-09 16:15:12.450365+00	2024-09-09 16:15:12.450365+00	\N	O5TIAOKVV5O3	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Senior	\N	1	\N
42	2024-09-09 16:15:13.193004+00	2024-09-09 16:15:13.193004+00	\N	TMUBESEWVBXJ	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Future	\N	1	\N
43	2024-09-09 16:15:14.184383+00	2024-09-09 16:15:14.184383+00	\N	D62QZNA98S7Z	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Senior	\N	1	\N
44	2024-09-09 16:15:14.923051+00	2024-09-09 16:15:14.923051+00	\N	CIC1SSMD3XGP	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Future	\N	1	\N
45	2024-09-09 16:15:15.611958+00	2024-09-09 16:15:15.611958+00	\N	BE6KZHKS9XDB	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Global	\N	1	\N
46	2024-09-09 16:15:16.40023+00	2024-09-09 16:15:16.40023+00	\N	XLNHY6DJZ0F0	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	International	\N	1	\N
47	2024-09-09 16:15:50.695784+00	2024-09-09 16:15:50.695784+00	\N	JR7TKTNJUDID	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Corporate	\N	1	\N
48	2024-09-09 16:15:51.459184+00	2024-09-09 16:15:51.459184+00	\N	I0TCAAVO2GXY	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Product	\N	1	\N
49	2024-09-09 16:15:55.040884+00	2024-09-09 16:15:55.040884+00	\N	1ZYSTWV4QMVJ	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Internal	\N	1	\N
50	2024-09-09 16:16:14.877439+00	2024-09-09 16:16:14.877439+00	\N	UXFYCGY95KXC	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Future	\N	1	\N
51	2024-09-09 16:16:15.682352+00	2024-09-09 16:16:15.682352+00	\N	WUIWBGCW05MW	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Central	\N	1	\N
52	2024-09-09 16:16:16.419903+00	2024-09-09 16:16:16.419903+00	\N	6YTUGWVXMRVX	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Human	\N	1	\N
53	2024-09-09 16:16:17.15895+00	2024-09-09 16:16:17.15895+00	\N	97S9FIJ5VYYX	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Forward	\N	1	\N
54	2024-09-09 16:16:17.823082+00	2024-09-09 16:16:17.823082+00	\N	2PBKLA1R2MZK	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Principal	\N	1	\N
55	2024-09-09 16:16:18.535024+00	2024-09-09 16:16:18.535024+00	\N	FV3WJXG453OG	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Dynamic	\N	1	\N
56	2024-09-09 16:16:19.234235+00	2024-09-09 16:16:19.234235+00	\N	GC338V99O1KE	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Chief	\N	1	\N
57	2024-09-09 16:16:19.896575+00	2024-09-09 16:16:19.896575+00	\N	XZKS814MQ3YO	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Future	\N	1	\N
58	2024-09-09 16:16:20.498545+00	2024-09-09 16:16:20.498545+00	\N	DIBM4UUVG7Q5	5	2	44	4	\N	\N	56000.00	397600.00	10.00	2	Corporate	\N	1	\N
59	2024-09-09 16:19:01.444206+00	2024-09-09 16:19:01.444206+00	\N	CQDU02871V23	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	2	Regional	\N	1	\N
60	2024-09-09 16:19:10.29132+00	2024-09-09 16:19:10.29132+00	\N	1128AO75ZVMS	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	2	Regional	\N	1	\N
61	2024-09-09 16:19:11.069529+00	2024-09-09 16:19:11.069529+00	\N	NMTUB38ADTNP	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	2	Regional	\N	1	\N
62	2024-09-09 16:19:11.840431+00	2024-09-09 16:19:11.840431+00	\N	MT370VCJTG8R	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	2	Regional	\N	1	\N
63	2024-09-09 16:19:12.51852+00	2024-09-09 16:19:12.51852+00	\N	PKG7ZH2JVGJM	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	2	Regional	\N	1	\N
64	2024-09-09 16:19:13.199278+00	2024-09-09 16:19:13.199278+00	\N	UV8C25QIUWVF	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	2	Regional	\N	1	\N
65	2024-09-09 16:19:18.385989+00	2024-09-09 16:19:18.385989+00	\N	PJ5C2KN3MT0R	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	2	Regional	\N	1	\N
66	2024-09-09 16:19:19.112662+00	2024-09-09 16:19:19.112662+00	\N	HUDYRFHH7IE9	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	2	Regional	\N	1	\N
67	2024-09-09 16:19:19.782555+00	2024-09-09 16:19:19.782555+00	\N	6F1DM82XHIDI	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	2	Regional	\N	1	\N
68	2024-09-09 16:19:20.504852+00	2024-09-09 16:19:20.504852+00	\N	QMU3CHODU3V3	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	2	Regional	\N	1	\N
69	2024-09-09 16:19:21.185477+00	2024-09-09 16:19:21.185477+00	\N	HLGPOLSQVYW7	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	2	Regional	\N	1	\N
70	2024-09-09 16:20:09.447832+00	2024-09-09 16:20:09.447832+00	\N	JWTWN0FCH7QI	5	2	1	4	\N	\N	1222.00	3792900.00	10.00	2	Legacy	\N	1	\N
71	2024-09-10 04:15:50.08992+00	2024-09-10 04:15:50.08992+00	\N	IM2HVFIBJSW2	5	2	1	4	\N	\N	1000.00	3439590.00	10.00	2	\N	\N	1	\N
72	2024-09-10 18:12:52.929661+00	2024-09-10 18:12:52.929661+00	\N	38AN0D69J05V	5	45	49	6	\N	\N	1111.00	2828100.00	10.00	2	\N	\N	1	\N
73	2024-09-10 18:16:08.579008+00	2024-09-10 18:16:08.579008+00	\N	8DAOHG30D780	5	45	49	6	\N	\N	1111.00	2828100.00	10.00	2	\N	0.00	2	\N
82	2024-09-11 02:56:18.768202+00	2024-09-11 02:58:43.022766+00	\N	T6M8QSKKAC33	5	3	2	6	6	6	1000.00	2919400.00	10.00	3	\N	\N	1	\N
76	2024-09-11 01:50:07.07266+00	2024-09-11 01:50:07.07266+00	\N	U4POWN9UGR4X	5	2	1	4	\N	\N	2000.00	6739590.00	10.00	2	\N	\N	1	\N
77	2024-09-11 01:50:20.601717+00	2024-09-11 01:50:20.601717+00	\N	AQNX1YN896N1	5	2	1	4	\N	\N	2000.00	6739590.00	10.00	2	\N	\N	1	\N
78	2024-09-11 01:51:48.867148+00	2024-09-11 01:51:48.867148+00	\N	LHC53JOH1FM4	5	2	1	4	\N	\N	2000.00	6739590.00	10.00	2	\N	\N	1	\N
79	2024-09-11 01:52:48.339105+00	2024-09-11 01:52:48.339105+00	\N	J0ZCZNUQDEO0	5	2	1	4	\N	\N	2000.00	6739590.00	10.00	2	\N	0.00	2	\N
80	2024-09-11 02:41:54.639061+00	2024-09-11 02:41:54.639061+00	\N	2KJRVNW6WYRJ	5	2	1	6	\N	\N	1000.00	2339590.00	10.00	2	\N	\N	1	\N
74	2024-09-10 18:28:15.24442+00	2024-09-11 01:42:27.537919+00	\N	IB00YT7NMVFE	5	2	1	7	\N	\N	124.00	821590.00	10.00	3	\N	\N	1	\N
81	2024-09-11 02:43:28.657088+00	2024-09-11 02:43:28.657088+00	\N	8QW5TGT950LD	5	2	1	6	\N	\N	1000.00	2339590.00	10.00	2	\N	\N	1	\N
83	2024-09-12 06:20:49.555582+00	2024-09-12 06:56:52.041398+00	\N	HHTMFD8ZW9IR	5	1	1	4	\N	\N	3000.00	739398.68	10.00	6	Senior	100.00	2	Hoppe - Satterfield
75	2024-09-11 01:48:12.166523+00	2024-09-11 02:43:52.568115+00	\N	MX3UIOZ4A8DW	5	2	1	4	4	4	2000.00	6739590.00	10.00	3	\N	\N	1	\N
84	2024-09-12 07:08:01.961743+00	2024-09-12 07:12:39.542481+00	\N	YJCE2P4BK976	5	1	1	4	\N	\N	1000.00	739398.68	10.00	3	Central	80.00	2	Hilll, Lang and Padberg
\.


--
-- Data for Name: internal_warehouse; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.internal_warehouse (id, created_at, updated_at, deleted_at, name, address_phone_number, province, district, ward, detail_address, lat, long, description, price_router, warehouse_status) FROM stdin;
5	2024-08-24 02:49:35.917924+00	2024-08-24 02:49:35.917924+00	\N	Kho Vĩnh Tân 2	942-566-7453	60	595	22984	8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318508418901722	108.80764164069608		1000.00	empty
6	2024-08-26 06:20:40.532406+00	2024-08-26 06:20:40.532406+00	\N	Kho Vĩnh Tân 4	977-587-2207	60	595	22984	8Q8X+X97 Tuy Phong, Bình Thuận, Việt Nam	11.31741431870949	108.79841484212815		2000.00	empty
3	2024-08-01 10:00:16.574091+00	2024-08-01 10:01:25.427928+00	\N	Kho Vĩnh Tân 5	914-514-6349	60	595	22984	8Q9V+6F6, tân 4, Tuy Phong, Bình Thuận, Việt Nam	11.318095268212533	108.79373933906133		4000.00	full
7	2024-08-26 06:29:14.220897+00	2024-08-26 06:29:14.220897+00	\N	Kho Vĩnh Tân 1	394-239-1738	60	595	22984	8Q9V+V2H Tuy Phong, Bình Thuận, Việt Nam	11.319694332509977	108.79260208249364		5000.00	empty
4	2024-08-01 10:01:25.427928+00	2024-08-28 04:00:25.177462+00	\N	Kho Vĩnh Tân 3	749-349-7019	60	595	22984	8RF8+46V Tuy Phong, Bình Thuận, Việt Nam	11.322858293046359	108.81554603374784		3000.00	full
\.


--
-- Data for Name: internal_warehouse_good_type; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.internal_warehouse_good_type (internal_good_type_id, internal_warehouse_id, id, created_at, updated_at, deleted_at) FROM stdin;
1	4	6	2024-08-01 10:01:25.434265+00	2024-08-01 10:01:25.434265+00	\N
1	5	7	2024-08-24 02:49:35.957761+00	2024-08-24 02:49:35.957761+00	\N
1	6	8	2024-08-26 06:20:40.630565+00	2024-08-26 06:20:40.630565+00	\N
1	7	9	2024-08-26 06:29:14.314771+00	2024-08-26 06:29:14.314771+00	\N
1	3	5	2024-08-01 10:00:16.583306+00	2024-08-01 10:00:16.583306+00	\N
\.


--
-- Data for Name: managers; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.managers (id, created_at, updated_at, deleted_at, full_name, birthday, cccd, date_range_cccd, place_range_cccd, owner_address, email, manager_password, phone_number, device_token, role, owner_car_id) FROM stdin;
\.


--
-- Data for Name: media; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.media (id, created_at, updated_at, deleted_at, media_url, media_format, media_size, media_width, media_height, media_hash) FROM stdin;
286	2024-11-21 08:58:56.671555+00	2024-11-21 08:58:56.671555+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732179535640210947.jpg	jpg	0.30	768	1024	3e8c92bb8ce67e2034741a7a67375b34777f7224328defb248f752df75954415
284	2024-11-21 08:56:57.057805+00	2024-11-21 08:56:57.057805+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732179416024247015.jpg	jpg	0.30	768	1024	854e5b2014bdbc491c13ed611a6cc9132c842cd6fd417caa90df5765855a0716
289	2024-11-21 09:02:06.112211+00	2024-11-21 09:02:06.112211+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732179725082353119.jpg	jpg	0.46	1024	666	96508df387906fd0ea7e0f869089ede670f50e613dff6f7a1079db6045a9ba90
283	2024-11-21 08:55:50.239669+00	2024-11-21 08:55:50.239669+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732179349209507405.jpg	jpg	0.30	768	1024	511cbec31841f6665d72942ca1d988906d8c77ec0414bee1c232c3cc1d4c2761
285	2024-11-21 08:57:53.599523+00	2024-11-21 08:57:53.599523+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732179472564734825.jpg	jpg	0.30	768	1024	02acbea776ccfefa5cb75cf31bec62e40eb3a24ac1fb449eb5a41a519f0cf52c
287	2024-11-21 09:00:09.865296+00	2024-11-21 09:00:09.865296+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732179608832510856.jpg	jpg	0.25	1024	576	9eefdd067227255ddb4eb5ea6bc336083dec6cc30a5ed0c877ba0fac0e816c1b
288	2024-11-21 09:01:27.769075+00	2024-11-21 09:01:27.769075+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732179686739243627.jpg	jpg	0.12	640	386	190017d805d6c639cde61215962037a17133824fb379fe3063971f7d8dad5ceb
150	2024-11-21 08:43:14.96934+00	2024-11-21 08:43:14.96934+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732178594910311931.jpg	jpg	0.30	768	1024	b524c3d89b90351f562cd8b36710585cdae255c9a65af664a70e57984d681f81
249	2024-11-21 08:49:26.340883+00	2024-11-21 08:49:26.340883+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732178966306402542.jpg	jpg	0.30	768	1024	674ae133c57dd32ff9f151f4dbb5ba547fe242e8ae9358ea3f8782a92da703bd
216	2024-11-21 08:47:50.914041+00	2024-11-21 08:47:50.914041+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732178870845357198.jpg	jpg	0.17	768	480	23ad985a9d502d009d7ae5a0ba6189ff16d50167ac47718b7b8fbd07a3d21294
183	2024-11-21 08:46:58.578711+00	2024-11-21 08:46:58.578711+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732178818525005223.jpg	jpg	0.30	768	1024	b9e7c3446917df9e5f2532e92597f385aebdae95fd8506849864cc42b1f8f030
282	2024-11-21 08:54:22.88942+00	2024-11-21 08:54:22.88942+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732179261860349462.jpg	jpg	0.30	768	1024	87be076898c69aab718899582c435af785f30e3762f9d2f85d39eb9b218c9071
290	2024-11-21 09:05:24.978699+00	2024-11-21 09:05:24.978699+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732179923943218684.jpg	jpg	0.46	1024	666	96508df387906fd0ea7e0f869089ede670f50e613dff6f7a1079db6045a9ba90
291	2024-11-21 09:05:32.289793+00	2024-11-21 09:05:32.289793+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732179931258923881.jpg	jpg	0.12	640	386	190017d805d6c639cde61215962037a17133824fb379fe3063971f7d8dad5ceb
292	2024-11-21 09:05:36.83214+00	2024-11-21 09:05:36.83214+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732179935801778332.jpg	jpg	0.25	1024	576	9eefdd067227255ddb4eb5ea6bc336083dec6cc30a5ed0c877ba0fac0e816c1b
296	2024-11-21 09:06:01.474337+00	2024-11-21 09:06:01.474337+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732179960526721542.jpg	jpg	0.12	640	386	190017d805d6c639cde61215962037a17133824fb379fe3063971f7d8dad5ceb
297	2024-11-21 09:06:53.263349+00	2024-11-21 09:06:53.263349+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732180012230758399.jpg	jpg	0.60	1920	2560	76361756a80c829b933264298ae3a587f2767937d3b6bb269978a10350e96e1c
84	2024-11-21 08:42:44.05747+00	2024-11-21 08:42:44.05747+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732178564024888322.jpg	jpg	0.30	768	1024	9737df8372ab088a09be6b6111d0a7bc42bdbc7fed0201e0e80711a2593b175f
11	2024-08-29 04:30:43.175178+00	2024-08-29 04:30:43.175178+00	2024-11-21 08:54:22.88942+00	http://localhost:8080/image-storage/M1724643871770955400.jpg	jpg	0.00	0	0	1837ba3d1720cc46b10646bca6c9d102ffdce01c0b37a40d61a018448dd160d9
10	2024-08-26 03:43:59.665366+00	2024-08-26 03:43:59.665366+00	2024-11-21 08:54:22.88942+00	http://localhost:8080/image-storage/M1724643871770955400.jpg	jpg	0.14	2460	1044	ef03716b10dd9f9b5c70935182c26bae02fdd8a1ab80bcb68b0361a7a3d24917
15	2024-10-15 13:51:26.57175+00	2024-10-15 13:51:26.57175+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/M1729000286569855915.jpg	jpg	0.17	2000	2000	83ef23aabdafcbbd7e14dc9460080e2eceb36331d63612af99903241a91df860
359	2024-11-22 04:21:01.082756+00	2024-11-22 04:21:01.082756+00	\N	http://holote.vn:8083/image-storage/IMG1732249260244641600.jpeg	jpeg	0.10	485	1024	\N
361	2024-11-22 04:22:48.071315+00	2024-11-22 04:22:48.071315+00	\N	http://holote.vn:8083/image-storage/IMG1732249367101455307.jpeg	jpeg	0.18	1920	1080	\N
363	2024-11-22 04:24:11.257496+00	2024-11-22 04:24:11.257496+00	\N	http://holote.vn:8083/image-storage/IMG1732249450417353196.jpeg	jpeg	0.18	1920	1080	\N
365	2024-11-22 04:24:45.388613+00	2024-11-22 04:24:45.388613+00	\N	http://holote.vn:8083/image-storage/IMG1732249484549947541.jpeg	jpeg	0.10	485	1024	\N
367	2024-11-22 04:25:09.435036+00	2024-11-22 04:25:09.435036+00	\N	http://:8080/image-storage/IMG1732249480214067000.jpeg	jpeg	0.44	1920	1080	\N
368	2024-11-22 04:28:16.450197+00	2024-11-22 04:28:16.450197+00	\N	http://:8080/image-storage/IMG1732249698169929000.jpeg	jpeg	0.18	1920	1080	\N
369	2024-11-22 04:28:16.565193+00	2024-11-22 04:28:16.565193+00	\N	http://:8080/image-storage/IMG1732249698169929000.jpeg	jpeg	0.44	1920	1080	\N
370	2024-11-22 04:29:26.957943+00	2024-11-22 04:29:26.957943+00	\N	http://:8080/image-storage/IMG1732249768670991500.jpeg	jpeg	0.44	1920	1080	\N
371	2024-11-22 04:29:27.058129+00	2024-11-22 04:29:27.058129+00	\N	http://:8080/image-storage/IMG1732249768670991500.jpeg	jpeg	0.18	1920	1080	\N
372	2024-11-22 04:29:39.46958+00	2024-11-22 04:29:39.46958+00	\N	http://:8080/image-storage/IMG1732249781164462100.jpeg	jpeg	0.18	1920	1080	\N
373	2024-11-22 04:29:39.668249+00	2024-11-22 04:29:39.668249+00	\N	http://:8080/image-storage/IMG1732249781164462100.jpeg	jpeg	0.44	1920	1080	\N
374	2024-11-22 04:29:56.604218+00	2024-11-22 04:29:56.604218+00	\N	http://:8080/image-storage/IMG1732249796548125800.jpeg	jpeg	0.18	1920	1080	\N
375	2024-11-22 04:32:41.062641+00	2024-11-22 04:32:41.062641+00	\N	http://holote.vn:8083/image-storage/IMG1732249960222294932.jpeg	jpeg	0.48	1024	768	\N
376	2024-11-22 04:36:00.650168+00	2024-11-22 04:36:00.650168+00	\N	http://holote.vn:8083/image-storage/IMG1732250159809925000.jpeg	jpeg	0.48	1024	768	\N
377	2024-11-22 04:37:57.036257+00	2024-11-22 04:37:57.036257+00	\N	http://:8080/image-storage/IMG1732250278741483500.jpeg	jpeg	0.18	1920	1080	\N
378	2024-11-22 04:37:57.172286+00	2024-11-22 04:37:57.172286+00	\N	http://:8080/image-storage/IMG1732250278741483500.jpeg	jpeg	0.44	1920	1080	\N
379	2024-11-22 04:39:47.280063+00	2024-11-22 04:39:47.280063+00	\N	http://:8080/image-storage/IMG1732250388993054700.jpeg	jpeg	0.01	124	251	\N
380	2024-11-22 04:39:49.662156+00	2024-11-22 04:39:49.662156+00	\N	http://:8080/image-storage/IMG1732250391377473000.jpeg	jpeg	0.01	124	251	\N
294	2024-11-21 09:06:00.297467+00	2024-11-21 09:06:00.297467+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732179959265546797.jpg	jpg	0.46	1024	666	96508df387906fd0ea7e0f869089ede670f50e613dff6f7a1079db6045a9ba90
293	2024-11-21 09:05:52.917621+00	2024-11-21 09:05:52.917621+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732179951885632618.jpg	jpg	0.25	1024	576	9eefdd067227255ddb4eb5ea6bc336083dec6cc30a5ed0c877ba0fac0e816c1b
295	2024-11-21 09:06:00.906554+00	2024-11-21 09:06:00.906554+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732179959958169064.jpg	jpg	0.17	768	480	23ad985a9d502d009d7ae5a0ba6189ff16d50167ac47718b7b8fbd07a3d21294
305	2024-11-21 22:14:39.597442+00	2024-11-21 22:14:39.597442+00	2024-11-21 08:54:22.88942+00	http:///image-storage/IMG1732227278423021771.jpeg	jpg	0.12	1080	1440	34427c7f81cd3a87b54f5136366a1db6462e91c259982026e4a8b13bc7c25b6e
307	2024-11-21 22:40:49.511501+00	2024-11-21 22:40:49.511501+00	2024-11-21 08:54:22.88942+00	http:///image-storage/IMG1732228848341495084.jpeg	jpeg	0.12	1080	1440	34427c7f81cd3a87b54f5136366a1db6462e91c259982026e4a8b13bc7c25b6e
311	2024-11-21 22:59:16.465889+00	2024-11-21 22:59:16.465889+00	2024-11-21 08:54:22.88942+00	http://holote.vn:8083/image-storage/IMG1732229955013723741.jpeg	jpeg	0.06	703	762	00172c5627c0beb500d361f8a5ecc0d18fc3fee4a20dda84d38cbb50dde2b551
313	2024-11-21 22:59:16.468017+00	2024-11-21 22:59:16.468017+00	2024-11-21 08:54:22.88942+00	http://holote.vn:8083/image-storage/IMG1732229955014227447.jpeg	jpeg	0.60	1920	2560	76361756a80c829b933264298ae3a587f2767937d3b6bb269978a10350e96e1c
309	2024-11-21 22:58:03.234443+00	2024-11-21 22:58:03.234443+00	2024-11-21 08:54:22.88942+00	http://holote.vn:8083/image-storage/IMG1732229882103646616.jpeg	jpeg	0.20	1536	2048	ac6c4b30b3e6585a5ca82e9d424100c0ef7f33f572e342a897726862356d7cfb
303	2024-11-21 10:17:41.038611+00	2024-11-21 10:17:41.038611+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732184259998921055.jpg	jpg	0.18	1013	1350	47301a8d78767faebb6e32f942dc1de9f81bd5783175d15dcb9d6838ab6d82d3
299	2024-11-21 09:21:00.06703+00	2024-11-21 09:21:00.06703+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732180859031253739.jpg	jpg	0.10	485	1024	6b835ab787504896211c5efac9518f1cecae2bdcfd48d63f4056c5010f4082c0
301	2024-11-21 09:22:55.994808+00	2024-11-21 09:22:55.994808+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732180974959581667.jpg	jpg	0.12	1080	1440	34427c7f81cd3a87b54f5136366a1db6462e91c259982026e4a8b13bc7c25b6e
302	2024-11-21 09:29:56.460888+00	2024-11-21 09:29:56.460888+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732181395383728549.jpg	jpg	0.30	768	1024	0ae81996f2a6a8165c4ddf09fc1749a7ce723ca767d8d12bb20b0363aa54d374
300	2024-11-21 09:22:02.768645+00	2024-11-21 09:22:02.768645+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732180921728318809.jpg	jpg	0.58	1024	768	f92c4e9cdc84bea809391fdc1a31c51c7084ec32ca10b3ed07c75cb8ddc26aa4
310	2024-11-21 22:59:16.330869+00	2024-11-21 22:59:16.330869+00	2024-11-21 08:54:22.88942+00	http://holote.vn:8083/image-storage/IMG1732229955016669990.jpeg	jpeg	0.46	1920	2560	48c32976c52bcae70c91f80a3eb5e7df8682bc207161dfab4addf23020d11abd
306	2024-11-21 22:15:44.104011+00	2024-11-21 22:15:44.104011+00	2024-11-21 08:54:22.88942+00	http://holote.vn/image-storage/IMG1732227342977470009.jpeg	jpg	0.12	1080	1440	34427c7f81cd3a87b54f5136366a1db6462e91c259982026e4a8b13bc7c25b6e
304	2024-11-21 21:15:38.870834+00	2024-11-21 21:15:38.870834+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732223737746789871.jpg	jpg	0.07	1080	1080	5a8f7b121acfa9b4046bf3ce117a9c259f727ac4abbd861de7fd8728a22f9c8a
308	2024-11-21 22:42:41.516999+00	2024-11-21 22:42:41.516999+00	2024-11-21 08:54:22.88942+00	http://holote.vn/image-storage/IMG1732228960384916969.jpeg	jpeg	0.12	1080	1440	34427c7f81cd3a87b54f5136366a1db6462e91c259982026e4a8b13bc7c25b6e
298	2024-11-21 09:14:15.608939+00	2024-11-21 09:14:15.608939+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732180454531787621.jpg	jpg	0.17	768	480	23ad985a9d502d009d7ae5a0ba6189ff16d50167ac47718b7b8fbd07a3d21294
312	2024-11-21 22:59:16.46682+00	2024-11-21 22:59:16.46682+00	2024-11-21 08:54:22.88942+00	http://holote.vn:8083/image-storage/IMG1732229955016886593.jpeg	jpeg	0.02	400	400	37215acbc769d1257648188423789f589c13078c19eeca8d0ff4ab3a439b89cb
315	2024-11-21 23:09:25.77469+00	2024-11-21 23:09:25.77469+00	2024-11-21 08:54:22.88942+00	http://holote.vn:8083/image-storage/IMG1732230564641380627.jpeg	jpeg	0.60	1920	2560	76361756a80c829b933264298ae3a587f2767937d3b6bb269978a10350e96e1c
13	2024-08-29 04:37:10.864015+00	2024-08-29 04:37:10.864015+00	2024-11-21 08:54:22.88942+00	http://localhost:8080/image-storage/M1724906264465187100.jpg	jpg	0.09	437	866	878b0c34fd29ba4003b1ce96599761c49cef40d7d851504fae898deff2c37ec3
7	2024-08-24 03:16:36.444972+00	2024-08-24 03:16:36.444972+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/M1724469396443666722.jpg	jpg	0.08	764	479	41403df14ea71ba6d8c8b58ac890d1168441b2e83cd7bf012f5780e0549a0faf
16	2024-10-24 09:18:09.309167+00	2024-10-24 09:18:09.309167+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/M1729761489260469325.jpg	jpg	0.19	720	899	01b14f62ca2e6be4a67b8daf1284117326c23d6f8e10a80d1d2446fd77828931
6	2024-08-22 10:13:34.521035+00	2024-08-22 10:13:34.521035+00	2024-11-21 08:54:22.88942+00	http://localhost:8080/image-storage/M1724321645713428800.jpg	jpg	0.01	232	206	e927f4a4a4100f7ee067b99e6940302dfabf6d27f416c287b4e6feceb2795593
314	2024-11-21 23:09:25.771818+00	2024-11-21 23:09:25.771818+00	2024-11-21 08:54:22.88942+00	http://holote.vn:8083/image-storage/IMG1732230564639320250.jpeg	jpeg	0.02	400	400	37215acbc769d1257648188423789f589c13078c19eeca8d0ff4ab3a439b89cb
316	2024-11-21 23:09:25.916578+00	2024-11-21 23:09:25.916578+00	2024-11-21 08:54:22.88942+00	http://holote.vn:8083/image-storage/IMG1732230564648758803.jpeg	jpeg	0.06	703	762	00172c5627c0beb500d361f8a5ecc0d18fc3fee4a20dda84d38cbb50dde2b551
14	2024-10-11 08:05:48.72615+00	2024-10-11 08:05:48.72615+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/M1728633948660097887.jpg	jpg	0.05	742	772	64817328da43c0232bdbe61390e7019de66adc5f39dbc0d51135d24bc907646c
12	2024-08-29 04:33:44.019003+00	2024-08-29 04:33:44.019003+00	2024-11-21 08:54:22.88942+00	http://localhost:8080/image-storage/M1724643871770955400.jpg	jpg	0.00	0	0	bedce5d6559a46d1584c66a500ea49346f5b756aa3799139eb2e33d41bde3716
318	2024-11-21 23:09:26.086417+00	2024-11-21 23:09:26.086417+00	2024-11-21 08:54:22.88942+00	http://holote.vn:8083/image-storage/IMG1732230564646512539.jpeg	jpeg	0.20	1536	2048	ac6c4b30b3e6585a5ca82e9d424100c0ef7f33f572e342a897726862356d7cfb
320	2024-11-21 23:09:48.262305+00	2024-11-21 23:09:48.262305+00	\N	http://holote.vn:8083/image-storage/IMG1732230587132627408.jpeg	jpeg	0.06	703	762	00172c5627c0beb500d361f8a5ecc0d18fc3fee4a20dda84d38cbb50dde2b551
321	2024-11-21 23:09:48.267871+00	2024-11-21 23:09:48.267871+00	\N	http://holote.vn:8083/image-storage/IMG1732230587137616037.jpeg	jpeg	0.20	1536	2048	ac6c4b30b3e6585a5ca82e9d424100c0ef7f33f572e342a897726862356d7cfb
322	2024-11-21 23:09:48.403578+00	2024-11-21 23:09:48.403578+00	\N	http://holote.vn:8083/image-storage/IMG1732230587138930926.jpeg	jpeg	0.19	720	899	01b14f62ca2e6be4a67b8daf1284117326c23d6f8e10a80d1d2446fd77828931
323	2024-11-21 23:09:48.40657+00	2024-11-21 23:09:48.40657+00	\N	http://holote.vn:8083/image-storage/IMG1732230587140923001.jpeg	jpeg	0.12	1080	1440	34427c7f81cd3a87b54f5136366a1db6462e91c259982026e4a8b13bc7c25b6e
360	2024-11-22 04:22:47.941512+00	2024-11-22 04:22:47.941512+00	\N	http://holote.vn:8083/image-storage/IMG1732249367101455070.jpeg	jpeg	0.44	1920	1080	\N
362	2024-11-22 04:24:11.257597+00	2024-11-22 04:24:11.257597+00	\N	http://holote.vn:8083/image-storage/IMG1732249450417353154.jpeg	jpeg	0.44	1920	1080	\N
364	2024-11-22 04:24:45.388733+00	2024-11-22 04:24:45.388733+00	\N	http://holote.vn:8083/image-storage/IMG1732249484549951406.jpeg	jpeg	0.37	1024	768	\N
366	2024-11-22 04:24:46.922018+00	2024-11-22 04:24:46.922018+00	\N	http://:8080/image-storage/IMG1732249480212931900.jpeg	jpeg	0.18	1920	1080	\N
17	2024-11-21 03:41:35.966713+00	2024-11-21 03:41:35.966713+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732160495882089422.jpg	jpg	3.92	8192	5464	aa0653b66446dcedfde8cc8323bdc52ffe8244d1f36c4bac5e235d5c012d6c1b
51	2024-11-21 08:41:26.578598+00	2024-11-21 08:41:26.578598+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732178486569665613.jpg	jpg	0.30	768	1024	4dfbdf45153b9469da56f2399a4c76e4ce9952ecab23d4be5ac2f72d67ea1e2c
319	2024-11-21 23:09:26.089951+00	2024-11-21 23:09:26.089951+00	2024-11-21 08:54:22.88942+00	http://holote.vn:8083/image-storage/IMG1732230564648050933.jpeg	jpeg	0.46	1920	2560	48c32976c52bcae70c91f80a3eb5e7df8682bc207161dfab4addf23020d11abd
317	2024-11-21 23:09:25.916648+00	2024-11-21 23:09:25.916648+00	2024-11-21 08:54:22.88942+00	http://holote.vn:8083/image-storage/IMG1732230564644422177.jpeg	jpeg	0.12	1080	1440	34427c7f81cd3a87b54f5136366a1db6462e91c259982026e4a8b13bc7c25b6e
18	2024-11-21 08:37:07.871258+00	2024-11-21 08:37:07.871258+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732178227810759777.jpg	jpg	0.30	768	1024	723943d44eb643f68f11fb3350082ad4c5745f18261732c8922e4497ace35243
117	2024-11-21 08:42:57.683607+00	2024-11-21 08:42:57.683607+00	2024-11-21 08:54:22.88942+00	http://103.124.93.27:8083/image-storage/IMG1732178577600525082.jpg	jpg	0.30	768	1024	2cfd4572283d2956f195f47b6c3f3730f5dd902ff41bbfb5a9bbbdd1825caa46
324	2024-11-21 23:09:48.583414+00	2024-11-21 23:09:48.583414+00	\N	http://holote.vn:8083/image-storage/IMG1732230587145889055.jpeg	jpeg	0.02	400	400	37215acbc769d1257648188423789f589c13078c19eeca8d0ff4ab3a439b89cb
325	2024-11-21 23:09:48.58559+00	2024-11-21 23:09:48.58559+00	\N	http://holote.vn:8083/image-storage/IMG1732230587133529544.jpeg	jpeg	0.60	1920	2560	76361756a80c829b933264298ae3a587f2767937d3b6bb269978a10350e96e1c
326	2024-11-21 23:09:48.588584+00	2024-11-21 23:09:48.588584+00	\N	http://holote.vn:8083/image-storage/IMG1732230587142569039.jpeg	jpeg	0.46	1920	2560	48c32976c52bcae70c91f80a3eb5e7df8682bc207161dfab4addf23020d11abd
327	2024-11-22 01:15:49.787957+00	2024-11-22 01:15:49.787957+00	\N	http://holote.vn:8083/image-storage/IMG1732238148639417965.jpeg	jpeg	0.07	1080	1080	57c8d88909287a7b7f02d35ab9700e3037a54e096b658924a222a9ac41106372
328	2024-11-22 01:15:49.799924+00	2024-11-22 01:15:49.799924+00	\N	http://holote.vn:8083/image-storage/IMG1732238148639424815.png	png	2.01	1536	1656	e3b775647bae1b5e69023cca5ad9510e009aeb34f982b77399c437c30e748f06
329	2024-11-22 01:25:07.21435+00	2024-11-22 01:25:07.21435+00	\N	http://holote.vn:8083/image-storage/IMG1732238706067987671.jpeg	jpeg	0.12	640	386	190017d805d6c639cde61215962037a17133824fb379fe3063971f7d8dad5ceb
330	2024-11-22 01:25:07.214588+00	2024-11-22 01:25:07.214588+00	\N	http://holote.vn:8083/image-storage/IMG1732238706063937651.jpeg	jpeg	0.46	1024	666	96508df387906fd0ea7e0f869089ede670f50e613dff6f7a1079db6045a9ba90
331	2024-11-22 01:26:16.306594+00	2024-11-22 01:26:16.306594+00	\N	http://holote.vn:8083/image-storage/IMG1732238775158813807.jpeg	jpeg	0.17	768	480	23ad985a9d502d009d7ae5a0ba6189ff16d50167ac47718b7b8fbd07a3d21294
332	2024-11-22 01:27:52.813003+00	2024-11-22 01:27:52.813003+00	\N	http://holote.vn:8083/image-storage/IMG1732238871663244592.jpeg	jpeg	0.25	1024	576	9eefdd067227255ddb4eb5ea6bc336083dec6cc30a5ed0c877ba0fac0e816c1b
333	2024-11-22 01:41:01.118695+00	2024-11-22 01:41:01.118695+00	\N	http://holote.vn:8083/image-storage/IMG1732239659966331563.jpeg	jpeg	0.30	768	1024	7ac146900b15964ca8dea541a034522526cf3ca2a927655d70a8b89a1d3ed555
334	2024-11-22 01:41:01.126921+00	2024-11-22 01:41:01.126921+00	\N	http://holote.vn:8083/image-storage/IMG1732239659976259637.jpeg	jpeg	0.30	768	1024	f6c6928254765c9f92e25fd7deb34c19f699d385cf230c0d9780a2afff369e61
335	2024-11-22 01:41:01.261573+00	2024-11-22 01:41:01.261573+00	\N	http://holote.vn:8083/image-storage/IMG1732239659970209204.jpeg	jpeg	0.30	768	1024	843fac31478f614b76532552d01679d980e577211d4d8dcfa509747a8ff55e44
336	2024-11-22 01:41:44.023598+00	2024-11-22 01:41:44.023598+00	\N	http://holote.vn:8083/image-storage/IMG1732239702873436926.jpeg	jpeg	0.30	768	1024	faf5c8836b8bb3b792877cbbc6f0dc214c588f4731f669d7994de584a54daad7
337	2024-11-22 01:41:44.024259+00	2024-11-22 01:41:44.024259+00	\N	http://holote.vn:8083/image-storage/IMG1732239702870326583.jpeg	jpeg	0.30	768	1024	006a9c42fa553e656c113f8507911e6b5d9d6b49b1bd19700a59fdc1ca6c2c0b
338	2024-11-22 01:41:44.158573+00	2024-11-22 01:41:44.158573+00	\N	http://holote.vn:8083/image-storage/IMG1732239702875404821.jpeg	jpeg	0.30	768	1024	cd47af606ed875a6f845f7d42985c4b5be182ef39f739bc02d003f6a5d2a30bd
339	2024-11-22 01:43:47.654214+00	2024-11-22 01:43:47.654214+00	\N	http://holote.vn:8083/image-storage/IMG1732239826502786340.jpeg	jpeg	0.30	768	1024	6380219b5b57bf9b429b1120b661933362b3fc066286d47aa56f035d8ea08121
340	2024-11-22 01:43:47.65416+00	2024-11-22 01:43:47.65416+00	\N	http://holote.vn:8083/image-storage/IMG1732239826505217359.jpeg	jpeg	0.30	768	1024	2353b4f8e0a3d84faa03a1ecd240e6b9a07d64b66b9bda1a90045f32fec0c53a
341	2024-11-22 01:43:47.791742+00	2024-11-22 01:43:47.791742+00	\N	http://holote.vn:8083/image-storage/IMG1732239826507303263.jpeg	jpeg	0.30	768	1024	1ceac3c0ae5ff88d9e0b4f344f5fe6bd4276ba5974930ba339cb6a371a3eb14b
342	2024-11-22 03:11:55.00566+00	2024-11-22 03:11:55.00566+00	\N	http://holote.vn:8083/image-storage/IMG1732245113926529854.jpeg	jpeg	0.47	1024	768	\N
343	2024-11-22 03:12:48.052288+00	2024-11-22 03:12:48.052288+00	\N	http://holote.vn:8083/image-storage/IMG1732245166974937528.jpeg	jpeg	0.47	1024	768	\N
344	2024-11-22 04:15:49.92998+00	2024-11-22 04:15:49.92998+00	\N	http://holote.vn:8083/image-storage/IMG1732248949091458369.jpeg	jpeg	0.55	1024	768	\N
345	2024-11-22 04:16:42.069291+00	2024-11-22 04:16:42.069291+00	\N	http://holote.vn:8083/image-storage/IMG1732249001230876970.jpeg	jpeg	0.55	1024	768	\N
346	2024-11-22 04:16:53.746895+00	2024-11-22 04:16:53.746895+00	\N	http://holote.vn:8083/image-storage/IMG1732249012909381881.jpeg	jpeg	0.10	485	1024	\N
347	2024-11-22 04:16:56.226765+00	2024-11-22 04:16:56.226765+00	\N	http://holote.vn:8083/image-storage/IMG1732249015389088999.jpeg	jpeg	0.10	485	1024	\N
348	2024-11-22 04:17:40.366624+00	2024-11-22 04:17:40.366624+00	\N	http://holote.vn:8083/image-storage/IMG1732249059528369576.jpeg	jpeg	0.30	768	1024	\N
349	2024-11-22 04:18:14.071868+00	2024-11-22 04:18:14.071868+00	\N	http://holote.vn:8083/image-storage/IMG1732249093233309028.jpeg	jpeg	0.30	768	1024	\N
350	2024-11-22 04:18:14.202978+00	2024-11-22 04:18:14.202978+00	\N	http://holote.vn:8083/image-storage/IMG1732249093233790333.jpeg	jpeg	0.30	768	1024	\N
351	2024-11-22 04:18:14.205501+00	2024-11-22 04:18:14.205501+00	\N	http://holote.vn:8083/image-storage/IMG1732249093233314009.jpeg	jpeg	0.30	768	1024	\N
352	2024-11-22 04:18:36.638518+00	2024-11-22 04:18:36.638518+00	\N	http://holote.vn:8083/image-storage/IMG1732249115801334205.jpeg	jpeg	0.30	768	1024	\N
353	2024-11-22 04:18:36.638278+00	2024-11-22 04:18:36.638278+00	\N	http://holote.vn:8083/image-storage/IMG1732249115800397513.jpeg	jpeg	0.30	768	1024	\N
354	2024-11-22 04:18:36.772883+00	2024-11-22 04:18:36.772883+00	\N	http://holote.vn:8083/image-storage/IMG1732249115802110144.jpeg	jpeg	0.30	768	1024	\N
355	2024-11-22 04:18:36.775881+00	2024-11-22 04:18:36.775881+00	\N	http://holote.vn:8083/image-storage/IMG1732249115802933644.jpeg	jpeg	0.30	768	1024	\N
356	2024-11-22 04:19:59.194684+00	2024-11-22 04:19:59.194684+00	\N	http://holote.vn:8083/image-storage/IMG1732249198356158805.jpeg	jpeg	0.18	1080	1920	\N
357	2024-11-22 04:20:52.388369+00	2024-11-22 04:20:52.388369+00	\N	http://holote.vn:8083/image-storage/IMG1732249251550167553.jpeg	jpeg	0.10	485	1024	\N
358	2024-11-22 04:21:01.082479+00	2024-11-22 04:21:01.082479+00	\N	http://holote.vn:8083/image-storage/IMG1732249260244623362.jpeg	jpeg	0.37	1024	768	\N
381	2024-11-22 04:43:16.856187+00	2024-11-22 04:43:16.856187+00	\N	http://:8080/image-storage/IMG1732250598543125700.jpeg	jpeg	0.01	124	251	19cfc6ce32d518a1dbd65c75f6d2fe99699a77a31012882d398c032345487527
382	2024-11-22 04:44:44.275991+00	2024-11-22 04:44:44.275991+00	\N	http://:8080/image-storage/IMG1732250685961756500.png	png	0.10	972	842	639a06ab905cab0bdbb6b2828707fc8efddb40f10850158cd0d4814cfdf4574e
383	2024-11-22 04:47:45.880047+00	2024-11-22 04:47:45.880047+00	\N	http://:8080/image-storage/IMG1732250867568237700.png	png	0.17	2000	2000	83ef23aabdafcbbd7e14dc9460080e2eceb36331d63612af99903241a91df860
384	2024-11-22 04:49:29.206131+00	2024-11-22 04:49:29.206131+00	\N	http://holote.vn:8083/image-storage/IMG1732250968362726398.jpeg	jpeg	0.48	1024	768	9291a3c2f8a80558eaeee96baffc99b1722b25081e9b1794b4269d66e9d21a02
385	2024-11-22 04:52:55.638316+00	2024-11-22 04:52:55.638316+00	\N	http://holote.vn:8083/image-storage/IMG1732251174794191273.jpeg	jpeg	0.47	1024	768	7896a68107ffcd2fb71edff49ddf1cdc575dda396869202d569535005da7d850
386	2024-11-22 04:53:51.248613+00	2024-11-22 04:53:51.248613+00	\N	http://holote.vn:8083/image-storage/IMG1732251230404365880.jpeg	jpeg	0.40	1024	768	16681105ecffb64e995bda60cc7116a2f9df2c0826621e18ca1703ca913769de
387	2024-11-22 04:55:12.935575+00	2024-11-22 04:55:12.935575+00	\N	http://holote.vn:8083/image-storage/IMG1732251312093261762.jpeg	jpeg	0.10	1024	485	fd1b788872a6a503a0a7ca1e3d79744902d9353b7aa753f73caeb7857d1ea05a
388	2024-11-22 04:55:13.066206+00	2024-11-22 04:55:13.066206+00	\N	http://holote.vn:8083/image-storage/IMG1732251312093253706.jpeg	jpeg	0.10	1024	485	fd1b788872a6a503a0a7ca1e3d79744902d9353b7aa753f73caeb7857d1ea05a
389	2024-11-22 04:56:54.192676+00	2024-11-22 04:56:54.192676+00	\N	http://holote.vn:8083/image-storage/IMG1732251413345640125.jpeg	jpeg	0.18	1024	768	36a591df021e230517057c70f8684bcce741a4acf7f12c946cb1c6857d273785
390	2024-11-22 04:56:54.322336+00	2024-11-22 04:56:54.322336+00	\N	http://holote.vn:8083/image-storage/IMG1732251413345639342.jpeg	jpeg	0.26	1024	768	3ebb12996581ec3afd033bfc40b8e4468f0592882ae28f25ed1991fa9c1bd064
391	2024-11-22 04:58:47.218988+00	2024-11-22 04:58:47.218988+00	\N	http://holote.vn:8083/image-storage/IMG1732251526375413801.jpeg	jpeg	0.10	1024	461	eee526ed58df87cb98f04bb758590cdc31e41d8b9b391019c50ede8c144833c9
392	2024-11-22 04:58:47.219135+00	2024-11-22 04:58:47.219135+00	\N	http://holote.vn:8083/image-storage/IMG1732251526375414415.jpeg	jpeg	0.10	1024	461	eee526ed58df87cb98f04bb758590cdc31e41d8b9b391019c50ede8c144833c9
393	2024-11-22 05:01:23.198111+00	2024-11-22 05:01:23.198111+00	\N	http://holote.vn:8083/image-storage/IMG1732251682353256760.jpeg	jpeg	0.17	1024	768	bb87699c66d76603862f3fa3f91ded095db4693b0966b05fe4b734f9d2af79e7
394	2024-11-22 05:01:23.198012+00	2024-11-22 05:01:23.198012+00	\N	http://holote.vn:8083/image-storage/IMG1732251682353237370.jpeg	jpeg	0.17	1024	768	0f7c4159835d466a2df6d03af874386a17db08c5b571c162f75f09e4eb662de8
395	2024-11-22 05:02:14.850096+00	2024-11-22 05:02:14.850096+00	\N	http://holote.vn:8083/image-storage/IMG1732251734005773808.jpeg	jpeg	0.17	1024	768	5438b868c57337953cbab23be1153f83987f3517034a35cf30e59d3d21e33b81
396	2024-11-22 05:02:14.850185+00	2024-11-22 05:02:14.850185+00	\N	http://holote.vn:8083/image-storage/IMG1732251734005742197.jpeg	jpeg	0.17	1024	768	d99ec1cc60038a19e3a613aaf1937052de04c07b290fe2dbc3abe00217bbcc9f
397	2024-11-22 06:49:10.217546+00	2024-11-22 06:49:10.217546+00	\N	http://holote.vn:8083/image-storage/IMG1732258149360221003.jpeg	jpeg	0.18	768	480	b951a7966e7e73872220ea11a056a2e530a4084bd3f5d536d0d8d2063c627fdd
398	2024-11-22 06:49:10.219006+00	2024-11-22 06:49:10.219006+00	\N	http://holote.vn:8083/image-storage/IMG1732258149360367426.jpeg	jpeg	0.47	1024	666	a5cb0a8c70b1b8ee26edc4c0451cb8be730a025b23a17cc988e8f38071aa1aad
399	2024-11-22 06:51:34.803859+00	2024-11-22 06:51:34.803859+00	\N	http://holote.vn:8083/image-storage/IMG1732258293947197258.jpeg	jpeg	0.17	1024	768	9289090ae337d86fd6e104ba323b39c08eb8e5b9cd9da78885ec0bb03190b9d7
400	2024-11-22 06:51:34.805678+00	2024-11-22 06:51:34.805678+00	\N	http://holote.vn:8083/image-storage/IMG1732258293947227678.jpeg	jpeg	0.17	1024	768	227b53932a4a822376df69adfc31dd64e54e5f9d91b274d5c417cc5949e34750
401	2024-11-22 06:58:07.381372+00	2024-11-22 06:58:07.381372+00	\N	http://holote.vn:8083/image-storage/IMG1732258686523057758.jpeg	jpeg	0.24	1024	768	64fcb161d96fef43bf1d6831725ff4db32de36015863d0adc52587dd55c3a3dd
402	2024-11-22 06:58:07.382043+00	2024-11-22 06:58:07.382043+00	\N	http://holote.vn:8083/image-storage/IMG1732258686523093258.jpeg	jpeg	0.22	1024	768	0210faab6343641ec6b471cea91d9c2fa6741ebf55e3fe32d082f5469c56d726
403	2024-11-22 06:59:43.783162+00	2024-11-22 06:59:43.783162+00	\N	http://holote.vn:8083/image-storage/IMG1732258782923502942.jpeg	jpeg	0.44	1024	768	08df374ab97b5a7368572182dc3dd8cb1a1f9d6e3a85fee8bff6b89f8d2bb8ad
404	2024-11-22 07:00:16.945545+00	2024-11-22 07:00:16.945545+00	\N	http://holote.vn:8083/image-storage/IMG1732258816084420733.jpeg	jpeg	0.49	1024	768	43df21a5a99e5b96c15eb88987fa51ab6d4657ee550e7d683ba15e3a162a2584
405	2024-11-22 07:01:02.938289+00	2024-11-22 07:01:02.938289+00	\N	http://holote.vn:8083/image-storage/IMG1732258862079362978.jpeg	jpeg	0.30	768	1024	1e3b7d3cd43a297d75c4d85b87a9af0b1a8168af61f3d7a67ff0c1d9908fe890
406	2024-11-22 07:02:53.74886+00	2024-11-22 07:02:53.74886+00	\N	http://holote.vn:8083/image-storage/IMG1732258972889316999.jpeg	jpeg	0.30	768	1024	46a695fea3a5fa22bc28e28b0105739bfa20602dacbd2467776c1746a1b41b51
407	2024-11-22 07:02:53.748774+00	2024-11-22 07:02:53.748774+00	\N	http://holote.vn:8083/image-storage/IMG1732258972889265549.jpeg	jpeg	0.30	768	1024	832a307b0ad23f077f1ebdc81437d794a5ed708473a903a5a4a9d18881eb7914
408	2024-11-22 07:02:55.801938+00	2024-11-22 07:02:55.801938+00	\N	http://holote.vn:8083/image-storage/IMG1732258974942335602.jpeg	jpeg	0.43	1024	768	f24bbd15c3fad1f1bf92da73e14d700c6243e83285af054f46a486be2254de44
409	2024-11-22 07:02:55.803302+00	2024-11-22 07:02:55.803302+00	\N	http://holote.vn:8083/image-storage/IMG1732258974942334731.jpeg	jpeg	0.48	1024	768	e7f955145f9f006cadb2837296f47152f20c50c9b19f492e9e990d77b1623b39
410	2024-11-22 07:17:50.528238+00	2024-11-22 07:17:50.528238+00	\N	http://holote.vn:8083/image-storage/IMG1732259869664663012.jpeg	jpeg	0.50	1024	768	90c3ee8b80a5c35e4dec1c558f08ce9bdaed25803191bb945a4877219d91482d
411	2024-11-22 07:19:04.321045+00	2024-11-22 07:19:04.321045+00	\N	http://holote.vn:8083/image-storage/IMG1732259943459082302.jpeg	jpeg	0.44	1024	768	695ffcb99bcef7d8bf4b732ad1a1184cc67ef54f04def44318758eaadb23a073
412	2024-11-22 07:19:33.738319+00	2024-11-22 07:19:33.738319+00	\N	http://holote.vn:8083/image-storage/IMG1732259972876037335.jpeg	jpeg	0.51	1024	768	6cf7a2c1a930c539a3e9eae65852aa9e92366b4981677d5dbd1e3edf9283e429
413	2024-11-22 07:29:30.050456+00	2024-11-22 07:29:30.050456+00	\N	http://holote.vn:8083/image-storage/IMG1732260569186520010.jpeg	jpeg	0.21	1024	768	47c6cb3d072d05dcbaababcf33552ee08fe98ea745807ca0b0360f13d2b35f68
414	2024-11-22 07:29:30.177672+00	2024-11-22 07:29:30.177672+00	\N	http://holote.vn:8083/image-storage/IMG1732260569186520283.jpeg	jpeg	0.31	1024	768	ffaefc5f34bb62d8bf646dc2b25ca5ec2f060c47f06d80bf58d469d7b901e8fe
415	2024-11-22 07:49:05.616249+00	2024-11-22 07:49:05.616249+00	\N	http://holote.vn:8083/image-storage/IMG1732261744751387649.jpeg	jpeg	0.47	1024	768	b905f176912b5b9c971b37611de87169a6fda1995fd04385f4920296fca48de0
416	2024-11-22 07:51:26.894416+00	2024-11-22 07:51:26.894416+00	\N	http://holote.vn:8083/image-storage/IMG1732261886030169341.jpeg	jpeg	0.25	1024	768	3962288ab4a502b2b8ce19b744c6632e406d1428a718791ddee8b731dce446f6
417	2024-11-22 07:51:26.894572+00	2024-11-22 07:51:26.894572+00	\N	http://holote.vn:8083/image-storage/IMG1732261886030173887.jpeg	jpeg	0.31	1024	768	012d48b2022be553c8996981b5096090a934be1fb06a25962728335551b665c0
419	2024-11-22 07:52:39.46752+00	2024-11-22 07:52:39.46752+00	\N	http://holote.vn:8083/image-storage/IMG1732261958603563666.jpeg	jpeg	0.23	1024	768	5d2ec51d9400343dd88d9bd320963c0ae777e6d7e911523519e85fd5d020e287
420	2024-11-22 08:04:30.187609+00	2024-11-22 08:04:30.187609+00	\N	http://holote.vn:8083/image-storage/IMG1732262669320622791.jpeg	jpeg	0.52	1024	768	05e60b979f9fb0093e79444b2d25e1661fe8442bd4faaef431fbef228be3d912
422	2024-11-22 08:05:51.03298+00	2024-11-22 08:05:51.03298+00	\N	http://holote.vn:8083/image-storage/IMG1732262750166099505.jpeg	jpeg	0.21	1024	768	0f7b540c503c25135d4f9158e4e7ac3fe1d25f775d39e28b8357e3a5a81f9eb7
423	2024-11-22 08:06:51.193742+00	2024-11-22 08:06:51.193742+00	\N	http://holote.vn:8083/image-storage/IMG1732262810324329815.jpeg	jpeg	0.42	1024	768	eaa60d9e028a96712855a0a0a9dd3fecc88902a8eb0da091241199445e0b704c
425	2024-11-22 08:08:09.065536+00	2024-11-22 08:08:09.065536+00	\N	http://holote.vn:8083/image-storage/IMG1732262888199007948.jpeg	jpeg	0.21	1024	768	07048f09e1dc11df593d493cf9662ff5bfa528ddae43c9dd497e3f6673a211e5
426	2024-11-22 08:18:03.679713+00	2024-11-22 08:18:03.679713+00	\N	http://holote.vn:8083/image-storage/IMG1732263482809958661.jpeg	jpeg	0.53	1024	768	7a5f5ae7ba513bd661fc37fd86556afe636ba9095d2d72b784fc9aec7caee725
428	2024-11-22 08:19:11.800505+00	2024-11-22 08:19:11.800505+00	\N	http://holote.vn:8083/image-storage/IMG1732263550932527878.jpeg	jpeg	0.23	1024	768	3aefa1fbe654a349896acf9581f2c8e1a9afd0d2ab8942e1c5e76c079a2b2dab
429	2024-11-22 08:20:34.082325+00	2024-11-22 08:20:34.082325+00	\N	http://holote.vn:8083/image-storage/IMG1732263633212945705.jpeg	jpeg	0.41	1024	768	637c589f0af531416413796448af741a058666b978d331bd3dd33a321ca54551
431	2024-11-22 08:21:39.873913+00	2024-11-22 08:21:39.873913+00	\N	http://holote.vn:8083/image-storage/IMG1732263699005260402.jpeg	jpeg	0.22	1024	768	ac5540a42f22cbb651ef87068dd375331c8e081a25c56e7f01571c2766afad53
418	2024-11-22 07:52:39.467395+00	2024-11-22 07:52:39.467395+00	\N	http://holote.vn:8083/image-storage/IMG1732261958603563537.jpeg	jpeg	0.25	1024	768	2a66f0199f49c0566221716ee4a85ba71cff8da56c1a580d15e4f41523476b60
421	2024-11-22 08:05:51.033075+00	2024-11-22 08:05:51.033075+00	\N	http://holote.vn:8083/image-storage/IMG1732262750166099705.jpeg	jpeg	0.26	1024	768	c942d8746464e2fb10c02e72cc3c14de27b2ff1fd1ba838c234c9d78ab545d34
424	2024-11-22 08:08:09.065449+00	2024-11-22 08:08:09.065449+00	\N	http://holote.vn:8083/image-storage/IMG1732262888199011815.jpeg	jpeg	0.25	1024	768	745ca0ba082d280cd5094f9da03af2f53cad683c0f18f8c54e1211870f07ea7d
427	2024-11-22 08:19:11.800417+00	2024-11-22 08:19:11.800417+00	\N	http://holote.vn:8083/image-storage/IMG1732263550932528214.jpeg	jpeg	0.28	1024	768	ba26f3bcf0f341d1d4b602ab36a87e8de69eb4a69dde9e5a6c5abaaf7ec36a48
430	2024-11-22 08:21:39.87399+00	2024-11-22 08:21:39.87399+00	\N	http://holote.vn:8083/image-storage/IMG1732263699005262266.jpeg	jpeg	0.30	1024	768	7e10bbe3bbe242f8b4f51ddfb60424dbe4264bfc00667e930d3e3412084e6f08
432	2024-11-22 09:14:52.907762+00	2024-11-22 09:14:52.907762+00	\N	http://holote.vn:8083/image-storage/IMG1732266892033398711.jpeg	jpeg	0.23	768	1024	7eba0555e6a080a6dbd56424c9ece23496b416932d6ac018d8726e76126e5810
433	2024-11-22 09:14:53.036512+00	2024-11-22 09:14:53.036512+00	\N	http://holote.vn:8083/image-storage/IMG1732266892033391042.jpeg	jpeg	0.42	1024	768	258b4d62d39d93dbec1382f1c4d4dd406a96d2d877f53ff39873a7895ceda2e4
434	2024-11-22 09:16:09.655146+00	2024-11-22 09:16:09.655146+00	\N	http://holote.vn:8083/image-storage/IMG1732266968780327835.jpeg	jpeg	0.31	1024	768	efd35aec3d179f85093ea013f6278eca59f6227a7cf93fa913ea85e4254e1a9d
435	2024-11-22 09:16:09.655231+00	2024-11-22 09:16:09.655231+00	\N	http://holote.vn:8083/image-storage/IMG1732266968780348651.jpeg	jpeg	0.28	1024	768	4898db127f4dfed8f9dfddcd239b3dc42541bc972d3bb72d3ca0e450b3ba2181
436	2024-11-22 09:18:58.806677+00	2024-11-22 09:18:58.806677+00	\N	http://holote.vn:8083/image-storage/IMG1732267137931297555.jpeg	jpeg	0.43	1024	768	64c19e1a0108780e1d0f4d6df0576a3123ec460b1c62719cfd92c2bb26112cca
437	2024-11-22 09:20:26.097342+00	2024-11-22 09:20:26.097342+00	\N	http://holote.vn:8083/image-storage/IMG1732267225222355607.jpeg	jpeg	0.24	1024	768	bf31a235200fea602497a1b36871014e36ab8de1c60302bacf61ed764149ff22
438	2024-11-22 09:20:26.097425+00	2024-11-22 09:20:26.097425+00	\N	http://holote.vn:8083/image-storage/IMG1732267225222367963.jpeg	jpeg	0.24	1024	768	42baf36270fc2460b589639427076ab52e867f1c7d7336cb8b1adf9c92341077
439	2024-11-22 09:29:31.558856+00	2024-11-22 09:29:31.558856+00	\N	http://holote.vn:8083/image-storage/IMG1732267770682165974.jpeg	jpeg	0.40	1024	768	15157d21e81a9b35dc7103b605776992b62fbf015efecfe03a007551d76dadf7
440	2024-11-22 09:30:45.32356+00	2024-11-22 09:30:45.32356+00	\N	http://holote.vn:8083/image-storage/IMG1732267844445441854.jpeg	jpeg	0.45	1024	768	955b56d6902c1c77353fdaa92574ccde739134aadfbdb2909d079d2e87cdfac2
441	2024-11-22 09:32:46.134821+00	2024-11-22 09:32:46.134821+00	\N	http://holote.vn:8083/image-storage/IMG1732267965258652370.jpeg	jpeg	0.28	1024	768	30a66a861c3aa582dec312270cbbcf845cebf96403697dafb3b6868bd7735a05
442	2024-11-22 09:32:46.134904+00	2024-11-22 09:32:46.134904+00	\N	http://holote.vn:8083/image-storage/IMG1732267965258639995.jpeg	jpeg	0.24	1024	768	851540adf8c1c75ac7290024cf9fd439da2551ad6be970baf616a5d285ab9d04
443	2024-11-22 09:35:36.671677+00	2024-11-22 09:35:36.671677+00	\N	http://holote.vn:8083/image-storage/IMG1732268135794741214.jpeg	jpeg	0.27	1024	768	096c01f07bb41a36156a06a924d1f3837bcbff3a376b6bccb0cdf175bc061bae
444	2024-11-22 09:35:36.67227+00	2024-11-22 09:35:36.67227+00	\N	http://holote.vn:8083/image-storage/IMG1732268135794742201.jpeg	jpeg	0.23	1024	768	700b7bbb134ed14da54198049013eeb56b504e72e9e3ad9028844a5be0b7790a
445	2024-11-22 09:53:32.776947+00	2024-11-22 09:53:32.776947+00	\N	http://holote.vn:8083/image-storage/IMG1732269211895905678.jpeg	jpeg	0.50	1024	768	14822aefdfdf67306e5160cc91183f318e07614887ffb8c6bd7fa65ee4512300
446	2024-11-22 09:55:24.308033+00	2024-11-22 09:55:24.308033+00	\N	http://holote.vn:8083/image-storage/IMG1732269323427024606.jpeg	jpeg	0.49	1024	768	45bf4696ffea7a1a3614ac20885f0f1078baf08f6f58c2bed5b73df88b2d5967
447	2024-11-23 03:57:19.855067+00	2024-11-23 03:57:19.855067+00	\N	http://holote.vn:8083/image-storage/IMG1732334238845550317.jpeg	jpeg	0.46	1024	768	9c698b6548ef43d52047b522ce074534ea4172e96930ea850f01e42e4ff6efec
448	2024-11-23 03:58:26.10738+00	2024-11-23 03:58:26.10738+00	\N	http://holote.vn:8083/image-storage/IMG1732334305097776457.jpeg	jpeg	0.26	1024	768	f3b631620272947079aaf79631964f0b1578b75e209c820801a7546cb89ff61b
449	2024-11-23 03:58:26.234605+00	2024-11-23 03:58:26.234605+00	\N	http://holote.vn:8083/image-storage/IMG1732334305097778221.jpeg	jpeg	0.29	1024	768	068617a897223b5c0a3ce6a3c3bbcc090385bdf1cba4a5e6c20b3f245bbb88ef
450	2024-11-23 04:00:30.303218+00	2024-11-23 04:00:30.303218+00	\N	http://holote.vn:8083/image-storage/IMG1732334429292466783.jpeg	jpeg	0.44	1024	768	bf3b22c9e5f06f7318cbcd43da599c1c4a35084105538dc94a6a9c587bb13b11
451	2024-11-23 04:01:52.166016+00	2024-11-23 04:01:52.166016+00	\N	http://holote.vn:8083/image-storage/IMG1732334511156468142.jpeg	jpeg	0.24	1024	768	eb5d6aeb5b657d17816600683738799eb1474ca14baa5d84ea9284811bf75750
452	2024-11-23 04:01:52.166096+00	2024-11-23 04:01:52.166096+00	\N	http://holote.vn:8083/image-storage/IMG1732334511156468250.jpeg	jpeg	0.22	1024	768	3f597820c05793debc5b876a2379f0c28725b5a0ede9d0450a1463ba771ec9f1
453	2024-11-25 03:39:46.461043+00	2024-11-25 03:39:46.461043+00	\N	http://holote.vn:8083/image-storage/IMG1732505985871694929.jpeg	jpeg	0.44	1024	768	3b41909ba630ed21aaf4be3ffd0ce6fea646a1fb9d113ff5c1b73195e0eb6a16
454	2024-11-25 03:40:59.66616+00	2024-11-25 03:40:59.66616+00	\N	http://holote.vn:8083/image-storage/IMG1732506059075446844.jpeg	jpeg	0.28	1024	768	db6c86570574147e8d04c81c06325285ed609559fbb9d945526995f3560f3a98
455	2024-11-25 03:40:59.795909+00	2024-11-25 03:40:59.795909+00	\N	http://holote.vn:8083/image-storage/IMG1732506059075447116.jpeg	jpeg	0.29	1024	768	f98b02ca92ac605a9d2089985598c0cf0806d54db5539f55f0802b51e024a626
456	2024-11-25 03:41:35.572426+00	2024-11-25 03:41:35.572426+00	\N	http://holote.vn:8083/image-storage/IMG1732506094983045202.jpeg	jpeg	0.29	1024	768	5cdc4e078f3c533bee5fcc6e7fb347e1be64df8d8ef1da5e67494f3e3f3c0530
457	2024-11-25 03:41:35.573009+00	2024-11-25 03:41:35.573009+00	\N	http://holote.vn:8083/image-storage/IMG1732506094983045343.jpeg	jpeg	0.23	1024	768	2aa3c1d7e49268ea0dbdcd73f37d901946f96a9746b523e639256b6cc3cae11a
458	2024-11-25 03:42:13.312084+00	2024-11-25 03:42:13.312084+00	\N	http://holote.vn:8083/image-storage/IMG1732506132722183862.jpeg	jpeg	0.26	1024	768	14fd22d96b57c39a5b39c034aebffb6cd4b0e0a1470506af0451349936b8ffbf
459	2024-11-25 03:42:13.312157+00	2024-11-25 03:42:13.312157+00	\N	http://holote.vn:8083/image-storage/IMG1732506132722183197.jpeg	jpeg	0.22	1024	768	822a1649177141d14fa6f34dd86b7b678c56a8f71710d40618d09a834637da7e
460	2024-11-25 03:42:56.878857+00	2024-11-25 03:42:56.878857+00	\N	http://holote.vn:8083/image-storage/IMG1732506176289806787.jpeg	jpeg	0.27	1024	768	bc77ad82e759fc9dd2b6a30285e63e372c8b262be314d7f64ad1097332746561
461	2024-11-25 03:42:56.879586+00	2024-11-25 03:42:56.879586+00	\N	http://holote.vn:8083/image-storage/IMG1732506176289806804.jpeg	jpeg	0.27	1024	768	654deb53aabc529978689ddf87267109061d689d64aa5121c3b7fd19b37e63fb
462	2024-11-25 03:43:46.264497+00	2024-11-25 03:43:46.264497+00	\N	http://holote.vn:8083/image-storage/IMG1732506225675007498.jpeg	jpeg	0.27	1024	768	2cd2e8e121a7dc97f85ae47c47835e67fbfbb8084733a1792fe7b479b7d00c53
464	2024-11-25 03:44:27.460152+00	2024-11-25 03:44:27.460152+00	\N	http://holote.vn:8083/image-storage/IMG1732506266870961706.jpeg	jpeg	0.28	1024	768	33e95a8ac20389f376a9a25d7c88e15d47fef1b944e9fbcafaa50b1d03029dbe
466	2024-11-25 03:50:04.712288+00	2024-11-25 03:50:04.712288+00	\N	http://holote.vn:8083/image-storage/IMG1732506604124020511.jpeg	jpeg	0.02	1024	768	022f4012ff22cd0a9098d89f8cdd8a3517ea8407f1c02270a4e1a2dba7469c92
468	2024-11-25 03:51:36.619994+00	2024-11-25 03:51:36.619994+00	\N	http://holote.vn:8083/image-storage/IMG1732506696030181353.jpeg	jpeg	0.27	1024	768	6e79dbba076116d44830690aa207934dc9f5fe6209618412ad9bfc12fe00ed53
470	2024-11-25 03:52:39.445522+00	2024-11-25 03:52:39.445522+00	\N	http://holote.vn:8083/image-storage/IMG1732506758855744361.jpeg	jpeg	0.26	1024	768	0ff4f6c5385d45d02de8dcd09e3aa7fbd51e64fd4baabc9f75c74f2dc23d6253
472	2024-11-25 03:53:19.470934+00	2024-11-25 03:53:19.470934+00	\N	http://holote.vn:8083/image-storage/IMG1732506798880672216.jpeg	jpeg	0.25	1024	768	68a362eaff378a99e49e558f206252a23dbab504f7f3574b0ff0d9ecdebed813
474	2024-11-25 03:53:38.543723+00	2024-11-25 03:53:38.543723+00	\N	http://holote.vn:8083/image-storage/IMG1732506817953644323.jpeg	jpeg	0.28	1024	768	3450f44f91f9ee205c50d1a1ea13f2610d12afdb6996ac1a151d76af8cc4ea46
476	2024-11-25 03:58:13.421706+00	2024-11-25 03:58:13.421706+00	\N	http://holote.vn:8083/image-storage/IMG1732507092830651213.jpeg	jpeg	0.26	1024	768	98e1d5e6de1da2f8a0073887ee4320a60cdc9e98c8d36ef2c85c62032f99f03e
478	2024-11-25 03:58:50.059793+00	2024-11-25 03:58:50.059793+00	\N	http://holote.vn:8083/image-storage/IMG1732507129467613598.jpeg	jpeg	0.28	1024	768	4f6132079725e8672047f4b80398c91b1fc0e91f21b049825e34117015e0e710
463	2024-11-25 03:43:46.264567+00	2024-11-25 03:43:46.264567+00	\N	http://holote.vn:8083/image-storage/IMG1732506225675007391.jpeg	jpeg	0.26	1024	768	f654d3389d19343170b42d7df81acf1273e980cbb2b52baeb90484d87a9e3a1c
465	2024-11-25 03:44:27.460233+00	2024-11-25 03:44:27.460233+00	\N	http://holote.vn:8083/image-storage/IMG1732506266870935071.jpeg	jpeg	0.24	1024	768	1931c1948b49452efbb9607f511c3ecf223096167a6f4adeac5b430a7c47a362
467	2024-11-25 03:50:04.712372+00	2024-11-25 03:50:04.712372+00	\N	http://holote.vn:8083/image-storage/IMG1732506604124008353.jpeg	jpeg	0.02	1024	768	23c109253867986f5a981aba8cab28b9230f1dac85085a372bc1792b41829cae
469	2024-11-25 03:51:36.6201+00	2024-11-25 03:51:36.6201+00	\N	http://holote.vn:8083/image-storage/IMG1732506696030176042.jpeg	jpeg	0.26	1024	768	e722e27c0810d4570b0cb5c57cc53c933f8a9305051b2c1de6dd102841d2730e
471	2024-11-25 03:52:39.445649+00	2024-11-25 03:52:39.445649+00	\N	http://holote.vn:8083/image-storage/IMG1732506758855744246.jpeg	jpeg	0.26	1024	768	9d71ea1ca1c63150a43866fd0eba2fecf18ab30c4a7bbc750a1772bf81420a78
473	2024-11-25 03:53:19.471019+00	2024-11-25 03:53:19.471019+00	\N	http://holote.vn:8083/image-storage/IMG1732506798880672119.jpeg	jpeg	0.26	1024	768	582e86afd81f50972eda923b3a0449cce95b2dd40cb545a802969895d4057acd
475	2024-11-25 03:53:38.543595+00	2024-11-25 03:53:38.543595+00	\N	http://holote.vn:8083/image-storage/IMG1732506817953643508.jpeg	jpeg	0.23	1024	768	21d1281b72d25119b285e0a5d71b8bd8db1acd07640cb8926858310fdc340211
477	2024-11-25 03:58:13.42179+00	2024-11-25 03:58:13.42179+00	\N	http://holote.vn:8083/image-storage/IMG1732507092830649656.jpeg	jpeg	0.25	1024	768	3a1d1eb8e52c118a6c15da536389d6e31d14b82928ed377ddf727e9f5a416118
479	2024-11-25 03:58:50.059864+00	2024-11-25 03:58:50.059864+00	\N	http://holote.vn:8083/image-storage/IMG1732507129467604779.jpeg	jpeg	0.26	1024	768	a2afaeca3081c12df35f3f2d7ea468e222630f8a22b23aa3f1a6c9cd85155989
480	2024-11-25 04:02:09.056249+00	2024-11-25 04:02:09.056249+00	\N	http://holote.vn:8083/image-storage/IMG1732507328465098922.jpeg	jpeg	0.22	1024	768	12b1dcbd46d3a1fd1dafffe20c53782d449ccef16fae931ec8d039cb65af4bb9
481	2024-11-25 04:02:09.185001+00	2024-11-25 04:02:09.185001+00	\N	http://holote.vn:8083/image-storage/IMG1732507328465099117.jpeg	jpeg	0.25	1024	768	81813a16d9ad765fa55eca65405f45472b7767b6169c27c7415e72254e60b01f
482	2024-11-25 04:20:28.600531+00	2024-11-25 04:20:28.600531+00	\N	http://holote.vn:8083/image-storage/IMG1732508428006682644.jpeg	jpeg	0.46	1024	768	50b8ad488817e618088dfb6997d8612b77486fb68d139349d0493e5a072b3013
483	2024-11-25 04:21:43.337251+00	2024-11-25 04:21:43.337251+00	\N	http://holote.vn:8083/image-storage/IMG1732508502744217835.jpeg	jpeg	0.27	1024	768	33cdf6dfaceaedc1b8807bc2d5077b77a0083a00883dcc5d0dae18b82d355208
484	2024-11-25 04:21:43.337338+00	2024-11-25 04:21:43.337338+00	\N	http://holote.vn:8083/image-storage/IMG1732508502744164634.jpeg	jpeg	0.27	1024	768	1dd66449d476dc5703501a6e9047a072f824ce9708af9292ef6b680596f3443b
485	2024-11-25 04:22:47.967486+00	2024-11-25 04:22:47.967486+00	\N	http://holote.vn:8083/image-storage/IMG1732508567373622302.jpeg	jpeg	0.43	1024	768	9279a453dffaee901c8245ba89fa6eef7c3b8476b93b63d66e011a07b4c80bc4
486	2024-11-25 04:24:02.164793+00	2024-11-25 04:24:02.164793+00	\N	http://holote.vn:8083/image-storage/IMG1732508641569636676.jpeg	jpeg	0.23	1024	768	0129dbdc2b0bc6cd0e5d6c1d9d4c731c22245a0a481acbe57c13f5cf77476462
487	2024-11-25 04:24:02.292459+00	2024-11-25 04:24:02.292459+00	\N	http://holote.vn:8083/image-storage/IMG1732508641569628571.jpeg	jpeg	0.24	1024	768	a3fbfbf34034609e95fc36eea17b91cc3a3102f851d6fff8a4dfa4f4edc981de
488	2024-11-25 07:58:53.294582+00	2024-11-25 07:58:53.294582+00	\N	http://holote.vn:8083/image-storage/IMG1732521532676148007.jpeg	jpeg	0.31	768	1024	4000722a7b0bd2662f6522a7c7ccd0c3e7787fb4015bc3ba712e0b1c669d2f4f
489	2024-11-25 07:58:53.427105+00	2024-11-25 07:58:53.427105+00	\N	http://holote.vn:8083/image-storage/IMG1732521532678458559.jpeg	jpeg	0.30	768	1024	f4d7a68366bd3236247a53933407abe02b437eecba9bccc1d2f5223923429aec
490	2024-11-25 08:02:54.988432+00	2024-11-25 08:02:54.988432+00	\N	http://holote.vn:8083/image-storage/IMG1732521774368820334.jpeg	jpeg	0.45	1024	768	4c4f83279bd2c8d17ef7fa98d2e2729509e0649776969b1ca919c483f8c1c8fa
491	2024-11-25 08:04:06.676045+00	2024-11-25 08:04:06.676045+00	\N	http://holote.vn:8083/image-storage/IMG1732521846053958956.jpeg	jpeg	0.28	1024	768	854c4591486c507cd103645f6c94fa9852c8bb358c2be3b8a2920338f9e92d2c
492	2024-11-25 08:04:06.676719+00	2024-11-25 08:04:06.676719+00	\N	http://holote.vn:8083/image-storage/IMG1732521846053963262.jpeg	jpeg	0.30	1024	768	4ebba359f0eca9a74f542fe1e0153b004b19ec1255e3f6f1c1ab410ef7130134
493	2024-11-25 08:30:32.126321+00	2024-11-25 08:30:32.126321+00	\N	http://holote.vn:8083/image-storage/IMG1732523431504339828.jpeg	jpeg	0.30	768	1024	743c0a90715c451659fa177f0040b8178152aaff7ccc6b49c56aa99c4589da3d
494	2024-11-25 08:30:32.255621+00	2024-11-25 08:30:32.255621+00	\N	http://holote.vn:8083/image-storage/IMG1732523431504366587.jpeg	jpeg	0.30	768	1024	debf5081c6164520403c45a26518e50b3a7c575621ac44c45cfc9097ee5403c2
495	2024-11-25 08:39:50.302159+00	2024-11-25 08:39:50.302159+00	\N	http://holote.vn:8083/image-storage/IMG1732523989678932998.jpeg	jpeg	0.30	768	1024	7ebda273e8f5feb87a24b41659b357e630cd7665fbbee790affb281b8109b0d2
496	2024-11-25 08:39:50.302461+00	2024-11-25 08:39:50.302461+00	\N	http://holote.vn:8083/image-storage/IMG1732523989678960124.jpeg	jpeg	0.30	768	1024	3871fbe1c91301b8e0173cbcaacf763e459a9b95c6993f91adaa10c60aeac521
497	2024-11-25 08:42:43.054891+00	2024-11-25 08:42:43.054891+00	\N	http://holote.vn:8083/image-storage/IMG1732524162430666315.jpeg	jpeg	0.30	768	1024	c7dd9790ea574e7a566d50edb4356dfc46b2fbab07b9f6683768aca2b5c49921
498	2024-11-25 08:47:13.77229+00	2024-11-25 08:47:13.77229+00	\N	http://holote.vn:8083/image-storage/IMG1732524433147343500.jpeg	jpeg	0.30	768	1024	b60b2eb204a58eae17946b57b562d4737d31d11bfc00daa566c6e8a38f1564e4
499	2024-11-25 08:48:35.222666+00	2024-11-25 08:48:35.222666+00	\N	http://holote.vn:8083/image-storage/IMG1732524514597554901.jpeg	jpeg	0.30	768	1024	727e1450e3ee8539ecbfd4819c4e3ae5b0bda9f843623e3ac02b5e03d3eccbdc
500	2024-11-25 08:50:00.462605+00	2024-11-25 08:50:00.462605+00	\N	http://holote.vn:8083/image-storage/IMG1732524599837487226.jpeg	jpeg	0.30	768	1024	2b7adb9a90f229ba348201ba83068ff23b5f62e82f56881ef1c27172f29ec38f
501	2024-11-25 08:52:01.613598+00	2024-11-25 08:52:01.613598+00	\N	http://holote.vn:8083/image-storage/IMG1732524720989220434.jpeg	jpeg	0.30	768	1024	6db2f3a34780808ed7c5ddbef8023263b6ff8f2a31384d83b24cd35c2ed11f2a
502	2024-11-25 09:12:03.307904+00	2024-11-25 09:12:03.307904+00	\N	http://holote.vn:8083/image-storage/IMG1732525922680659240.jpeg	jpeg	0.30	768	1024	8a7db0603d4a965cac360c2140e851a0d3a9de200b471753758c1309dff7ddc6
503	2024-11-25 09:12:50.272035+00	2024-11-25 09:12:50.272035+00	\N	http://holote.vn:8083/image-storage/IMG1732525969644978432.jpeg	jpeg	0.31	768	1024	a4080b5be7e6c28ee466a19da74ed36ee8cb64945ba690489e2f927d86b3aa8c
504	2024-11-25 09:18:37.654725+00	2024-11-25 09:18:37.654725+00	\N	http://holote.vn:8083/image-storage/IMG1732526317027413284.jpeg	jpeg	0.30	768	1024	68a9f12a0d1fbeb04f4d9a7e69a4615b38bb548f5186247c733e8bf9ca289f3b
505	2024-11-25 09:19:53.084596+00	2024-11-25 09:19:53.084596+00	\N	http://holote.vn:8083/image-storage/IMG1732526392456181408.jpeg	jpeg	0.30	768	1024	da4fd62856671e577a0176414653891979dcd898967ec7ae7b28f31159b01d92
506	2024-11-25 09:53:27.792601+00	2024-11-25 09:53:27.792601+00	\N	http://holote.vn:8083/image-storage/IMG1732528407159807356.jpeg	jpeg	0.49	1024	768	55cafe2c2d3515409435d56a478042aa18bec577a7b2351e2b5ca2d09918a53b
507	2024-11-25 09:53:52.301117+00	2024-11-25 09:53:52.301117+00	\N	http://holote.vn:8083/image-storage/IMG1732528431667354738.jpeg	jpeg	0.49	1024	768	a7ae317ec6bbc03dafcaab67ed5377eaa6bd5a6eee805e106bbe2c4185de88a5
508	2024-11-25 10:00:50.757616+00	2024-11-25 10:00:50.757616+00	\N	http://holote.vn:8083/image-storage/IMG1732528850124405629.jpeg	jpeg	0.47	1024	768	6b40fbc20df99d8810c50fe6bde591aafa0c718e7aac504150611893e54648dd
509	2024-11-25 10:02:08.159591+00	2024-11-25 10:02:08.159591+00	\N	http://holote.vn:8083/image-storage/IMG1732528927526281953.jpeg	jpeg	0.27	1024	768	32537e2ab51417e3b040ef17af82835e97ace5c268a9fc1380edc0c171dcdf98
510	2024-11-25 10:02:08.286269+00	2024-11-25 10:02:08.286269+00	\N	http://holote.vn:8083/image-storage/IMG1732528927526277202.jpeg	jpeg	0.25	1024	768	b8678e03cd45e53b1f99677a6c1af1d3eac88bdc7dd207b3818df4e3f4b32745
511	2024-11-26 01:57:14.707731+00	2024-11-26 01:57:14.707731+00	\N	http://holote.vn:8083/image-storage/IMG1732586233968932827.jpeg	jpeg	0.17	1024	768	935500150c323c0b2119269274582bbe1b45ebe638ccda7fa5d42d8cd04d1687
512	2024-11-26 01:57:14.834953+00	2024-11-26 01:57:14.834953+00	\N	http://holote.vn:8083/image-storage/IMG1732586233968939416.jpeg	jpeg	0.17	1024	768	a55a51ccddcc5be9b2fe523daf664ef7e5f223572acd17737df43c39e28bca3f
513	2024-11-26 01:57:47.957807+00	2024-11-26 01:57:47.957807+00	\N	http://holote.vn:8083/image-storage/IMG1732586267219205708.jpeg	jpeg	0.17	1024	768	95c252b9e51dd681c1cd23bf117d1652ab26e8a912a3d719caec7ee104303c88
514	2024-11-26 01:57:47.957924+00	2024-11-26 01:57:47.957924+00	\N	http://holote.vn:8083/image-storage/IMG1732586267219252153.jpeg	jpeg	0.17	1024	768	8f9d235055a1cc67b9740c9eaf4da3978ac6ad3a08eac236c1016261fe8c3d85
515	2024-11-26 01:59:01.741945+00	2024-11-26 01:59:01.741945+00	\N	http://holote.vn:8083/image-storage/IMG1732586341002709919.jpeg	jpeg	0.17	1024	768	a0077268b891f289e012854f25c8c521be86448a6c23c61df5930c4f744c1d66
516	2024-11-26 01:59:01.742955+00	2024-11-26 01:59:01.742955+00	\N	http://holote.vn:8083/image-storage/IMG1732586341002736479.jpeg	jpeg	0.17	1024	768	80665a8d6361f85a5ff1e121aff1fd0b303ac8d59f9317736297ced52691b9dd
517	2024-11-26 01:59:26.452929+00	2024-11-26 01:59:26.452929+00	\N	http://holote.vn:8083/image-storage/IMG1732586365714419583.jpeg	jpeg	0.17	1024	768	c6741e3d2d48060420687bb8673894c2e92642f1a23cad4c7e18df352a58951b
518	2024-11-26 01:59:26.45302+00	2024-11-26 01:59:26.45302+00	\N	http://holote.vn:8083/image-storage/IMG1732586365714410324.jpeg	jpeg	0.17	1024	768	873a99337033921d67671a1ae9afbb164649fd078d4b831f07a57127ee64ee7b
519	2024-11-26 02:11:47.474712+00	2024-11-26 02:11:47.474712+00	\N	http://holote.vn:8083/image-storage/IMG1732587106733518699.jpeg	jpeg	0.30	768	1024	a370fb7f02f9c8ca9d4af0bae66c0101f2331900e4e7fc57c5f72d83a952cef4
520	2024-11-26 02:13:32.027067+00	2024-11-26 02:13:32.027067+00	\N	http://holote.vn:8083/image-storage/IMG1732587211285604906.jpeg	jpeg	0.30	768	1024	5fcc69545681945a7608f28c2910b58a265c666d61a200f512dad586eaead8c3
521	2024-11-26 02:13:52.147136+00	2024-11-26 02:13:52.147136+00	\N	http://holote.vn:8083/image-storage/IMG1732587231405775743.jpeg	jpeg	0.30	768	1024	5768f02193e87d84d6dbb325718cf4b8cc609828847708eef1f30e6e8fa1f557
522	2024-11-26 03:49:49.471873+00	2024-11-26 03:49:49.471873+00	\N	http://holote.vn:8083/image-storage/IMG1732592988718080423.jpeg	jpeg	0.48	1024	768	e614ccc691e5b7b610d3d4ac5c9e73369942b2bcc19ad8851007fb4df28c8c5f
523	2024-11-26 03:51:06.405113+00	2024-11-26 03:51:06.405113+00	\N	http://holote.vn:8083/image-storage/IMG1732593065652039114.jpeg	jpeg	0.27	1024	768	68cf3447e5ac7efc4c3f5860f75bddd47082e3c096fdf32c82e51a05d5486541
524	2024-11-26 03:51:06.40521+00	2024-11-26 03:51:06.40521+00	\N	http://holote.vn:8083/image-storage/IMG1732593065651984099.jpeg	jpeg	0.25	1024	768	4998b7b5f72f2e183f5a03f7ed6fbed84665ccc0c4aa32af81bfbcded2a24ee2
525	2024-11-26 06:24:32.985773+00	2024-11-26 06:24:32.985773+00	\N	http://holote.vn:8083/image-storage/IMG1732602272212875668.jpeg	jpeg	0.47	1024	768	822ff3bef9219aaa42aae24fdb08fa1f6b963cdefc3ba70918469860c7fbefcc
526	2024-11-26 06:25:41.450739+00	2024-11-26 06:25:41.450739+00	\N	http://holote.vn:8083/image-storage/IMG1732602340679470746.jpeg	jpeg	0.26	1024	768	499dcd8d6162a3f13158174d1fb566a23aea419965d07a2ffede8ababe32af8e
527	2024-11-26 06:25:41.577358+00	2024-11-26 06:25:41.577358+00	\N	http://holote.vn:8083/image-storage/IMG1732602340679473551.jpeg	jpeg	0.26	1024	768	f15b594db9f5913d1d52856235a1f1d8b9c3af03e3db1eb1082c30d2e230c355
528	2024-11-26 06:34:49.584338+00	2024-11-26 06:34:49.584338+00	\N	http://holote.vn:8083/image-storage/IMG1732602888811015045.jpeg	jpeg	0.51	1024	768	b047240484abf017634e4d3918b8f4937f827eea2b2aeeb13da477bd8e363b64
529	2024-11-26 06:36:03.709336+00	2024-11-26 06:36:03.709336+00	\N	http://holote.vn:8083/image-storage/IMG1732602962937918344.jpeg	jpeg	0.24	1024	768	11da13891f4c573aebbb6d6b58fe58dac0f917b77e468d0fd783170109505427
530	2024-11-26 06:36:03.709583+00	2024-11-26 06:36:03.709583+00	\N	http://holote.vn:8083/image-storage/IMG1732602962937918466.jpeg	jpeg	0.25	1024	768	5ff7c978ff5110862e0a2072dd5ccfde46a4dca96b6930abdb990ecc23e5ac4d
531	2024-11-26 06:45:14.346882+00	2024-11-26 06:45:14.346882+00	\N	http://holote.vn:8083/image-storage/IMG1732603513573231243.jpeg	jpeg	0.47	1024	768	d1f13f020d1543f6ab8df023ec870f4990f0fbf401693dc30b5d09665f79a53e
532	2024-11-26 06:48:05.8242+00	2024-11-26 06:48:05.8242+00	\N	http://holote.vn:8083/image-storage/IMG1732603685049846568.jpeg	jpeg	0.44	1024	768	d040d29cbb4d268aefd872e141670e615bbe31e716fec79ef871faabe9d7041f
533	2024-11-26 07:12:41.298797+00	2024-11-26 07:12:41.298797+00	\N	http://holote.vn:8083/image-storage/IMG1732605160521071261.jpeg	jpeg	0.30	768	1024	ffa37f5a0bc8d9df7204d1158fa90c5df0d538c4e2e89d14e186588a6bdafd7c
534	2024-11-26 07:15:00.118901+00	2024-11-26 07:15:00.118901+00	\N	http://holote.vn:8083/image-storage/IMG1732605299341860435.jpeg	jpeg	0.30	768	1024	d54e069544acf55483d3b197959962bbc62e69bf37134bde4d3ccab9e23a1671
535	2024-11-26 07:20:28.948381+00	2024-11-26 07:20:28.948381+00	\N	http://holote.vn:8083/image-storage/IMG1732605628170989842.jpeg	jpeg	0.30	768	1024	0acb08843b20e147ec88516db7df1cf75a8603b448aa1e431cf92f78de6f0dbd
536	2024-11-26 07:20:56.876972+00	2024-11-26 07:20:56.876972+00	\N	http://holote.vn:8083/image-storage/IMG1732605656099011499.jpeg	jpeg	0.30	768	1024	26a330ce12e74905322904d63dfc5cd6d662d44d9efa691ff29d8ff5a5c7d9db
537	2024-11-26 07:21:16.020066+00	2024-11-26 07:21:16.020066+00	\N	http://holote.vn:8083/image-storage/IMG1732605675241827299.jpeg	jpeg	0.30	768	1024	89a990261f9145f97af2f79d6e53c832e9a6a056a4e49de8aa14633394579088
538	2024-11-26 07:21:33.930587+00	2024-11-26 07:21:33.930587+00	\N	http://holote.vn:8083/image-storage/IMG1732605693024611326.jpeg	jpeg	0.30	768	1024	d974c4daffc78afaeb978e1a8e675afadbb5b8a0555efd69d58ef99119908062
539	2024-11-26 07:21:51.36048+00	2024-11-26 07:21:51.36048+00	\N	http://holote.vn:8083/image-storage/IMG1732605710582461689.jpeg	jpeg	0.30	768	1024	35d702b8f7ff01a000fdb659f6a5247fe3a2e2f3d12cc8d521de4731a9809229
540	2024-11-26 07:22:10.395112+00	2024-11-26 07:22:10.395112+00	\N	http://holote.vn:8083/image-storage/IMG1732605729616934665.jpeg	jpeg	0.30	768	1024	b8f8812728ab851553f6bc81b97aba0b01b1c5599f9f7933d2b6d6a97bd3ddf0
541	2024-11-26 07:22:29.964306+00	2024-11-26 07:22:29.964306+00	\N	http://holote.vn:8083/image-storage/IMG1732605749186645531.jpeg	jpeg	0.30	768	1024	c224bcb4ef88b2c90d63c3ec249a8863089b502aa3a75e872fff078c831a4b2b
542	2024-11-26 07:24:26.2277+00	2024-11-26 07:24:26.2277+00	\N	http://holote.vn:8083/image-storage/IMG1732605865449476214.jpeg	jpeg	0.30	768	1024	70ddc13a4e64afe48950c74f4ee7853ff6cfdebf81702ad34675d551e5e0ba2a
543	2024-11-26 07:24:46.344376+00	2024-11-26 07:24:46.344376+00	\N	http://holote.vn:8083/image-storage/IMG1732605885565649802.jpeg	jpeg	0.30	768	1024	a3da04819519aab13b00b8e0f213ac7af729ff82fc2f8402dac6229e85c71c81
544	2024-11-26 07:26:24.411462+00	2024-11-26 07:26:24.411462+00	\N	http://holote.vn:8083/image-storage/IMG1732605983632592141.jpeg	jpeg	0.30	768	1024	97003055c34313ad58d11fda592c22f3defdaf295807bf46a99bc039cefd75c8
545	2024-11-26 07:32:37.379861+00	2024-11-26 07:32:37.379861+00	\N	http://holote.vn:8083/image-storage/IMG1732606356601202283.jpeg	jpeg	0.30	768	1024	49b183d1c3c1dc55979e8bce4ca41de595eb29ae3defe1524f593cfab43b42e1
546	2024-11-26 07:32:55.818047+00	2024-11-26 07:32:55.818047+00	\N	http://holote.vn:8083/image-storage/IMG1732606375039443705.jpeg	jpeg	0.30	768	1024	8f90bf66c9ec1c5f5d442e503312dd6b7a7649573d3fa3d82d4ad2d44dc4283d
547	2024-11-26 07:36:28.746021+00	2024-11-26 07:36:28.746021+00	\N	http://holote.vn:8083/image-storage/IMG1732606587966508859.jpeg	jpeg	0.30	768	1024	0d691838acaae83991401c6d5c820ed0cd08402f9e204ddd6adc741f63d9b043
548	2024-11-26 07:36:50.085572+00	2024-11-26 07:36:50.085572+00	\N	http://holote.vn:8083/image-storage/IMG1732606609305861882.jpeg	jpeg	0.31	768	1024	7a134136b4f675992d0a335f2ab96da11570a6700e907f46e13d320ec831fd34
549	2024-11-26 07:37:15.368704+00	2024-11-26 07:37:15.368704+00	\N	http://holote.vn:8083/image-storage/IMG1732606634589549414.jpeg	jpeg	0.30	768	1024	5daf8b7eb3cc8de52020cf2f3a0b7e706bf7059a0724bb85c47e74a567855fd7
550	2024-11-26 07:39:55.818643+00	2024-11-26 07:39:55.818643+00	\N	http://holote.vn:8083/image-storage/IMG1732606795037897983.jpeg	jpeg	0.51	1024	768	26bb2995d74861eda150533fef0b51d822ca7634ff7abf97f8cc42a85ee6e751
551	2024-11-26 07:41:32.645587+00	2024-11-26 07:41:32.645587+00	\N	http://holote.vn:8083/image-storage/IMG1732606891866187366.jpeg	jpeg	0.30	768	1024	cccfacc75c7b9f8c7298d62a2ddbd94da0ccdece838fce61a082322822302973
553	2024-11-26 07:43:23.371023+00	2024-11-26 07:43:23.371023+00	\N	http://holote.vn:8083/image-storage/IMG1732607002590764676.jpeg	jpeg	0.25	1024	768	fa13abbf246f2102b4e4105d19c12e3a8c3e5630fec354ffa9896bedde79d2d5
554	2024-11-26 07:46:21.655358+00	2024-11-26 07:46:21.655358+00	\N	http://holote.vn:8083/image-storage/IMG1732607180873863020.jpeg	jpeg	0.53	1024	768	28b5122fddc797bfb86d516e13af23fec7fe12428f371b935ce050d1c72d1aaf
556	2024-11-26 07:48:54.320365+00	2024-11-26 07:48:54.320365+00	\N	http://holote.vn:8083/image-storage/IMG1732607333539702117.jpeg	jpeg	0.26	1024	768	2f250532cb62eb63731af9f84dc9e498d81140ba4eb2ad5e5017810bf35dd21b
552	2024-11-26 07:43:23.370942+00	2024-11-26 07:43:23.370942+00	\N	http://holote.vn:8083/image-storage/IMG1732607002590764684.jpeg	jpeg	0.29	1024	768	40594b89fcce25f0ed0611c672cb9eddc7cd1ec8b54d34a4b903c3bbb7115e60
555	2024-11-26 07:48:54.320443+00	2024-11-26 07:48:54.320443+00	\N	http://holote.vn:8083/image-storage/IMG1732607333539616710.jpeg	jpeg	0.26	1024	768	7b80863c05c53027f5f58052e8f38bd4965dd5d1eae0406c4a31690b4af41251
557	2024-11-26 07:57:19.303588+00	2024-11-26 07:57:19.303588+00	\N	http://holote.vn:8083/image-storage/IMG1732607838521569795.jpeg	jpeg	0.46	1024	768	b09d346ee6c71a1093e98220a53f16ef375b00486f2aa7c1047fc27a1f055311
558	2024-11-26 07:59:23.991443+00	2024-11-26 07:59:23.991443+00	\N	http://holote.vn:8083/image-storage/IMG1732607963208610479.jpeg	jpeg	0.47	1024	768	af0c7f543220d9af9eeb7084b52c64c472a8e9a95483dc34358c874b86c58fdf
559	2024-11-26 08:00:59.950251+00	2024-11-26 08:00:59.950251+00	\N	http://holote.vn:8083/image-storage/IMG1732608059167715073.jpeg	jpeg	0.45	1024	768	00cd7b114e7210fa7ec10b41892cfbb71e96cea838231c6a368ef22365d1dcbc
560	2024-11-26 08:01:33.893345+00	2024-11-26 08:01:33.893345+00	\N	http://holote.vn:8083/image-storage/IMG1732608093109039858.jpeg	jpeg	0.48	1024	768	eecb3e3c63f5870abff67a90015c2424863519eb4ff0234781d93bb5a4dd3c8a
561	2024-11-26 08:04:01.756682+00	2024-11-26 08:04:01.756682+00	\N	http://holote.vn:8083/image-storage/IMG1732608240973288476.jpeg	jpeg	0.49	1024	768	cb3add46504d3f9c1263a8c4b50d12fa8dcdb6450709420fc23b7809377fdbeb
562	2024-11-26 08:04:33.611406+00	2024-11-26 08:04:33.611406+00	\N	http://holote.vn:8083/image-storage/IMG1732608272827262140.jpeg	jpeg	0.52	1024	768	ac0de44661704bdefaa54e822b8c77b2afbaca3bb25b027d7a2afad403dd1325
563	2024-11-27 03:25:31.345821+00	2024-11-27 03:25:31.345821+00	\N	http://holote.vn:8083/image-storage/IMG1732677930432836009.jpeg	jpeg	0.02	1024	768	470678e6daaf980d1c33ebc91a7bde65b71ac127154e99aea7389eaa5f5bde0c
564	2024-11-27 03:25:31.476133+00	2024-11-27 03:25:31.476133+00	\N	http://holote.vn:8083/image-storage/IMG1732677930432858767.jpeg	jpeg	0.02	1024	768	c148500e899bae1c3eff8b21de3d905e646e35f5fb24e6d81af3a186467542ab
565	2024-11-27 03:27:09.829548+00	2024-11-27 03:27:09.829548+00	\N	http://holote.vn:8083/image-storage/IMG1732678028918439160.jpeg	jpeg	0.02	1024	768	2fb92d3675ec2e07975072e9f24e81f9c4c0a48ab8600a2c99bd0a855f85aad6
566	2024-11-27 03:27:09.829872+00	2024-11-27 03:27:09.829872+00	\N	http://holote.vn:8083/image-storage/IMG1732678028918451588.jpeg	jpeg	0.03	1024	768	50e485bc205d9b612734ecc6b4805bba6318dbba7a11a58373911bed0e2b398b
567	2024-11-27 03:43:13.163544+00	2024-11-27 03:43:13.163544+00	\N	http://holote.vn:8083/image-storage/IMG1732678992249326403.jpeg	jpeg	0.03	768	1024	3dc0ef5e7e7d46d3718f5b39ed83c7cd6c292575673d3e9b25c3400c1ad06f42
568	2024-11-27 09:43:11.999335+00	2024-11-27 09:43:11.999335+00	\N	http://holote.vn:8083/image-storage/IMG1732700591041208030.jpeg	jpeg	0.48	1024	768	460259167ac74797933af6567493fda2324c2df8c292042fd5f109adae493b55
569	2024-11-27 09:44:44.665183+00	2024-11-27 09:44:44.665183+00	\N	http://holote.vn:8083/image-storage/IMG1732700683706701182.jpeg	jpeg	0.47	1024	768	3ab5329b208c44fd5b376f88a2b82c5b8adb4e415b287daef14ee1f71165fb5d
570	2024-11-27 20:10:35.422489+00	2024-11-27 20:10:35.422489+00	\N	http://holote.vn:8083/image-storage/IMG1732738234394610230.jpeg	jpeg	0.03	768	1024	9cbad51ac4c2415ac3cc763a0c89992a631e347ddda0f5d78a33d95b2e58bad8
571	2024-11-27 20:10:56.863029+00	2024-11-27 20:10:56.863029+00	\N	http://holote.vn:8083/image-storage/IMG1732738255835174247.jpeg	jpeg	0.02	768	1024	c1f29c148761b5c3f13b60dacfd9cb802859506119042b06b70dbbc87bdcd05f
572	2024-11-27 20:11:38.489238+00	2024-11-27 20:11:38.489238+00	\N	http://holote.vn:8083/image-storage/IMG1732738297461009758.jpeg	jpeg	0.03	768	1024	e76ebbd0b682fef0982571373411d223f39ee5db91b61f4bc3d3a84ec24efdd6
573	2024-11-28 01:39:24.48646+00	2024-11-28 01:39:24.48646+00	\N	http://holote.vn:8083/image-storage/IMG1732757963417486680.jpeg	jpeg	0.30	768	1024	f84563b04cef6cbe9c3bec18beb115713e2220bb13dcc8d70249050248b3580f
574	2024-11-28 01:39:46.812801+00	2024-11-28 01:39:46.812801+00	\N	http://holote.vn:8083/image-storage/IMG1732757985744594778.jpeg	jpeg	0.30	768	1024	20a8544ece5e15aeb5debfb86864df8cee44b9c9d7bd4b74285796e590312a22
575	2024-11-28 01:40:08.581089+00	2024-11-28 01:40:08.581089+00	\N	http://holote.vn:8083/image-storage/IMG1732758007511728611.jpeg	jpeg	0.30	768	1024	bfd3744bfa4db5127cee0310f452567425b33fc5f8e434964ca9614cefc5c4df
576	2024-11-28 02:17:13.254984+00	2024-11-28 02:17:13.254984+00	\N	http://holote.vn:8083/image-storage/IMG1732760232181862477.jpeg	jpeg	0.46	1024	768	d5ca7544a5e587b362db44e3ef27fd1cbf7293cde97469a716271a0467869e97
577	2024-11-28 02:19:36.784552+00	2024-11-28 02:19:36.784552+00	\N	http://holote.vn:8083/image-storage/IMG1732760375709206345.jpeg	jpeg	0.46	1024	768	6585e4be2452601f9227a1f0405627f8fa407451d80d6e17e43760a9c0918fba
578	2024-11-28 02:26:26.137924+00	2024-11-28 02:26:26.137924+00	\N	http://holote.vn:8083/image-storage/IMG1732760785061899389.jpeg	jpeg	0.50	1024	768	c7ae4137cf4e2caebb9b0658c1cebc89acde0bcc375d7c7f9c88eb33c487addc
579	2024-11-28 02:26:26.265692+00	2024-11-28 02:26:26.265692+00	\N	http://holote.vn:8083/image-storage/IMG1732760785061887697.jpeg	jpeg	0.50	1024	768	bfd26faeb3de5b72dcb9c66017f8842052fd8e28e7e06c9f200ba190edd20116
580	2024-11-28 02:27:58.072825+00	2024-11-28 02:27:58.072825+00	\N	http://holote.vn:8083/image-storage/IMG1732760876997762699.jpeg	jpeg	0.44	1024	768	07ed6ac6b67288ec0e2eb34d24750a8bf57eb1020dd4f86d5ae4a1370a97abdc
581	2024-11-28 02:38:56.201761+00	2024-11-28 02:38:56.201761+00	\N	http://holote.vn:8083/image-storage/IMG1732761535125056135.jpeg	jpeg	0.50	1024	768	6e8c66fb260ca475b777234933c0aa9f2678d51b9c0ad2aa21323082a54a016d
582	2024-11-28 02:39:23.360136+00	2024-11-28 02:39:23.360136+00	\N	http://holote.vn:8083/image-storage/IMG1732761562284613300.jpeg	jpeg	0.43	1024	768	d67755528ccfb4c8677d613992efdeb8748f64b250d4faeb48e96d79024e6079
583	2024-11-28 02:39:44.565489+00	2024-11-28 02:39:44.565489+00	\N	http://holote.vn:8083/image-storage/IMG1732761583490082042.jpeg	jpeg	0.44	1024	768	71980b3f14d3feedaa87087869dee667136d879a4e5f9e0e7b46e6f7f5be4957
584	2024-11-28 02:46:52.394782+00	2024-11-28 02:46:52.394782+00	\N	http://holote.vn:8083/image-storage/IMG1732762011318005032.jpeg	jpeg	0.44	1024	768	15800e05a9f3344dbd1be4c4ca7992994335c23c92154047c6ce87e69b3aa2a6
585	2024-11-28 02:52:59.888507+00	2024-11-28 02:52:59.888507+00	\N	http://holote.vn:8083/image-storage/IMG1732762378811455753.jpeg	jpeg	0.43	1024	768	613565100df5ff4758a2b267e124ed8872585033dccea906e991fc9b1b6aa83f
586	2024-11-28 02:53:19.230941+00	2024-11-28 02:53:19.230941+00	\N	http://holote.vn:8083/image-storage/IMG1732762398154055287.jpeg	jpeg	0.43	1024	768	051300debc57229ad92c196734b82377522c888e442af6f57b5d9648cc1b2a61
587	2024-11-28 02:53:49.548199+00	2024-11-28 02:53:49.548199+00	\N	http://holote.vn:8083/image-storage/IMG1732762428469845739.jpeg	jpeg	0.45	1024	768	175a28cb84a84678bf4c5d7dfd28f1178c46fc8273482a14b485cc23208e9003
588	2024-11-28 03:08:25.833036+00	2024-11-28 03:08:25.833036+00	\N	http://holote.vn:8083/image-storage/IMG1732763304753554148.jpeg	jpeg	0.47	1024	768	5c0122d357b485b4b24c2d1377cbcfc7a2ecfa7a886ddf2884e6f9c93ee67f7a
589	2024-11-28 03:09:04.273582+00	2024-11-28 03:09:04.273582+00	\N	http://holote.vn:8083/image-storage/IMG1732763343193597849.jpeg	jpeg	0.46	1024	768	5bfe70d662ccad75038f4c3b8a11beae6371e8d29200a43ce3a96e55b73458ef
590	2024-11-28 03:09:25.757538+00	2024-11-28 03:09:25.757538+00	\N	http://holote.vn:8083/image-storage/IMG1732763364678114200.jpeg	jpeg	0.45	1024	768	918970c5ffa315ac54b10b26dd217c5bf3ec8c2ca606e15d8109f41fc93d7d8f
591	2024-11-28 03:12:03.330683+00	2024-11-28 03:12:03.330683+00	\N	http://holote.vn:8083/image-storage/IMG1732763522249072878.jpeg	jpeg	0.55	1024	768	71d6adb1bf42b748787d9cee46d880b4797f57e36682acb938d005377cae5dd7
592	2024-11-28 03:27:31.644726+00	2024-11-28 03:27:31.644726+00	\N	http://holote.vn:8083/image-storage/IMG1732764450563254843.jpeg	jpeg	0.44	1024	768	569d162d20284ea8338ec11eec7511505a9eaaba4f6998bf60e2d8a22043db24
593	2024-11-28 03:47:06.560371+00	2024-11-28 03:47:06.560371+00	\N	http://holote.vn:8083/image-storage/IMG1732765625475956751.jpeg	jpeg	0.45	1024	768	f4dd97567efcaee92e3f0fe01e003462845b8890a7c743e5d70123bcbfc3e572
594	2024-11-28 03:47:31.282082+00	2024-11-28 03:47:31.282082+00	\N	http://holote.vn:8083/image-storage/IMG1732765650198289340.jpeg	jpeg	0.26	768	1024	4001e53eed27afc924f2cbfd21a6b87df76c05be7b46cc24f45306cf14c14433
595	2024-11-28 03:47:51.594707+00	2024-11-28 03:47:51.594707+00	\N	http://holote.vn:8083/image-storage/IMG1732765670511923398.jpeg	jpeg	0.30	768	1024	2c41c01ea5a4bf0ebf1f387b68b1d2b697763eafe563ed59b5a84fd9c4de1a3e
596	2024-11-28 03:48:25.354696+00	2024-11-28 03:48:25.354696+00	\N	http://holote.vn:8083/image-storage/IMG1732765704270843795.jpeg	jpeg	0.30	768	1024	04b2ca811ed0e8ba9bca2a61a249feed2d46614fa3d9f022fc51401007292be7
597	2024-11-28 03:52:25.973312+00	2024-11-28 03:52:25.973312+00	\N	http://holote.vn:8083/image-storage/IMG1732765944889037996.jpeg	jpeg	0.30	768	1024	a3d97895157b60ae7e8b1378247e5c6c4f5de985e7d6f56043fd6ce7e448f6fe
598	2024-11-28 04:53:08.028503+00	2024-11-28 04:53:08.028503+00	\N	http://holote.vn:8083/image-storage/IMG1732769586937396222.jpeg	jpeg	0.30	768	1024	001d36b0f5c191020e3cbcc201c3e62d1fd633b3f8afc9cfa101b772fb92da04
599	2024-11-28 04:53:29.362571+00	2024-11-28 04:53:29.362571+00	\N	http://holote.vn:8083/image-storage/IMG1732769608271944565.jpeg	jpeg	0.30	768	1024	470bec4627917d446b89feffcc47e43afbd9957c487cdda4fe4cc8ad83c1e904
600	2024-11-28 04:57:54.666931+00	2024-11-28 04:57:54.666931+00	\N	http://holote.vn:8083/image-storage/IMG1732769873575968999.jpeg	jpeg	0.30	768	1024	3cfca3847ef350d9973a9728c493f469bf3e6a07ba6ce990d0109ba0bc07efd4
601	2024-11-28 04:58:15.959917+00	2024-11-28 04:58:15.959917+00	\N	http://holote.vn:8083/image-storage/IMG1732769894868667748.jpeg	jpeg	0.30	768	1024	97ca0badefa8e0417b7d7b45336d528322427f2b8b12a171d6db7b3cb03fa272
602	2024-11-28 04:58:49.32717+00	2024-11-28 04:58:49.32717+00	\N	http://holote.vn:8083/image-storage/IMG1732769928235661897.jpeg	jpeg	0.30	768	1024	fa4e57311fcf10ed69ec15669caf0f684b47faf0f104669083f72d9e1c4cf9c4
603	2024-11-28 04:59:06.485251+00	2024-11-28 04:59:06.485251+00	\N	http://holote.vn:8083/image-storage/IMG1732769945393559301.jpeg	jpeg	0.30	768	1024	4935f0e937ead577ef3f77b0c526c168ae74c7ecdd6f7f2b9f21c1df23c69784
604	2024-11-28 05:02:48.745067+00	2024-11-28 05:02:48.745067+00	\N	http://holote.vn:8083/image-storage/IMG1732770167652779610.jpeg	jpeg	0.30	768	1024	17a28b52892601bb4553a42e9d136497a41515765d36ec65e45639c3d1fd8e5a
605	2024-11-28 06:02:54.40114+00	2024-11-28 06:02:54.40114+00	\N	http://holote.vn:8083/image-storage/IMG1732773773301915700.jpeg	jpeg	0.30	768	1024	1012aa9192c341351c871e0060aca56abca75b054b9b6971214014f9d8d1d9d0
606	2024-11-28 06:03:12.874118+00	2024-11-28 06:03:12.874118+00	\N	http://holote.vn:8083/image-storage/IMG1732773791775443663.jpeg	jpeg	0.30	768	1024	7fbfe3c4204b3014c73294017d13dde8c1e195bca0c09f551a0bf5b7eb6343a5
607	2024-11-28 06:03:31.220538+00	2024-11-28 06:03:31.220538+00	\N	http://holote.vn:8083/image-storage/IMG1732773810120868251.jpeg	jpeg	0.30	768	1024	aadc35af7a7c05a6aaaf0816bcf1ed84dd760a3a9048962ad2751665a369e892
608	2024-11-28 06:04:09.011536+00	2024-11-28 06:04:09.011536+00	\N	http://holote.vn:8083/image-storage/IMG1732773847912496027.jpeg	jpeg	0.30	768	1024	886bd818cbebcd43ae3ae1b65c121af58c840e777933904ec8391d37fbd530ad
609	2024-11-28 06:04:42.165532+00	2024-11-28 06:04:42.165532+00	\N	http://holote.vn:8083/image-storage/IMG1732773881065806022.jpeg	jpeg	0.30	768	1024	7434f5660e933f1ffd2050623c25ead64dc1f2d7d3f7d38e1cc4b461e9b63433
610	2024-11-28 06:05:16.109476+00	2024-11-28 06:05:16.109476+00	\N	http://holote.vn:8083/image-storage/IMG1732773915010529706.jpeg	jpeg	0.30	768	1024	0fea22bbcf8e0409d6d54edccaff03c81dc159fb8c77417a851442bc026565fa
611	2024-11-28 06:07:59.370286+00	2024-11-28 06:07:59.370286+00	\N	http://holote.vn:8083/image-storage/IMG1732774078270703355.jpeg	jpeg	0.30	768	1024	71c5ca0832913f6b48b0b9be84b21eae971496eb6bfbf57377810b47ffa5f0e3
612	2024-11-28 06:08:31.550033+00	2024-11-28 06:08:31.550033+00	\N	http://holote.vn:8083/image-storage/IMG1732774110450049057.jpeg	jpeg	0.30	768	1024	1f0a718951b309973a746d3950661ba5080089f96ef26dfc948eab30510dea1d
613	2024-11-28 06:23:32.549457+00	2024-11-28 06:23:32.549457+00	\N	http://holote.vn:8083/image-storage/IMG1732775011447283911.jpeg	jpeg	0.30	768	1024	453eeec2581f63843e8a0b3c355a33ec269f6021fc63c83bad312af0e8b2a210
614	2024-11-28 06:23:52.160088+00	2024-11-28 06:23:52.160088+00	\N	http://holote.vn:8083/image-storage/IMG1732775031058077283.jpeg	jpeg	0.31	768	1024	a7b24c8e1fa89fbc67e126705ab8d59c01c79714e2bfc8ea4af81aecb70b3c53
615	2024-11-28 06:47:12.117902+00	2024-11-28 06:47:12.117902+00	\N	http://holote.vn:8083/image-storage/IMG1732776431011349721.jpeg	jpeg	0.47	1024	768	cf4373e889312e9ff4df8c953222b9de8226c720ed7b5306a058bd079ffabae5
616	2024-11-28 06:47:12.483692+00	2024-11-28 06:47:12.483692+00	\N	http://holote.vn:8083/image-storage/IMG1732776431419889283.jpeg	jpeg	0.30	768	1024	9ffb2ea47237e378749614fa37aabcf8f2c5c8487a9ed30701d59110ab848aa2
617	2024-11-28 06:47:30.219314+00	2024-11-28 06:47:30.219314+00	\N	http://holote.vn:8083/image-storage/IMG1732776449113353112.jpeg	jpeg	0.49	1024	768	b129bc1e908fbc0dc1092527bdcf164e78551d24ce34e218c6e3232b4a216c33
618	2024-11-28 06:47:32.348089+00	2024-11-28 06:47:32.348089+00	\N	http://holote.vn:8083/image-storage/IMG1732776451285288014.jpeg	jpeg	0.30	768	1024	cf46475c777fbadffed20efeb53f2a51b59fc31ebe3ae87d08937a28a2410ea6
619	2024-11-28 06:48:02.17019+00	2024-11-28 06:48:02.17019+00	\N	http://holote.vn:8083/image-storage/IMG1732776481064927365.jpeg	jpeg	0.47	1024	768	30053a5d0f1fc2817ca3a96c8962fe4b5e563ffa542d69eca8289f848522abd5
620	2024-11-28 06:48:26.892054+00	2024-11-28 06:48:26.892054+00	\N	http://holote.vn:8083/image-storage/IMG1732776505786814066.jpeg	jpeg	0.47	1024	768	b06472a57fd222d5aa66b954341e8a297bac8964e13596ce8eeddea493048780
621	2024-11-28 06:48:53.107639+00	2024-11-28 06:48:53.107639+00	\N	http://holote.vn:8083/image-storage/IMG1732776532002912563.jpeg	jpeg	0.30	768	1024	eea3a310338b70f4414c6b62327dfe25de672d814858e41c65943f6083bb6e34
622	2024-11-28 06:48:56.060675+00	2024-11-28 06:48:56.060675+00	\N	http://holote.vn:8083/image-storage/IMG1732776534954607933.jpeg	jpeg	0.44	1024	768	40be7b833da4c6ad7f289f3c8e2a1e0ba7f3a58714c9793ba5bfed02ab5fc115
623	2024-11-28 06:49:13.624925+00	2024-11-28 06:49:13.624925+00	\N	http://holote.vn:8083/image-storage/IMG1732776552519918908.jpeg	jpeg	0.44	1024	768	d8af81b3cb7f79a003c710fa56d6548e90e367011b573796e90df1bcb047dcdc
624	2024-11-28 06:49:44.465133+00	2024-11-28 06:49:44.465133+00	\N	http://holote.vn:8083/image-storage/IMG1732776583359925088.jpeg	jpeg	0.30	768	1024	42584a80404d7378090dca5da32e6d935aad0e9fd20df522c322aee797da36e3
625	2024-11-28 06:50:16.187621+00	2024-11-28 06:50:16.187621+00	\N	http://holote.vn:8083/image-storage/IMG1732776615082329586.jpeg	jpeg	0.30	768	1024	8af529651fedba7991ee2f2c79f91401d6c6f116d71c41b3ccb7aad1d1dab2f0
626	2024-11-28 06:50:50.788932+00	2024-11-28 06:50:50.788932+00	\N	http://holote.vn:8083/image-storage/IMG1732776649683468764.jpeg	jpeg	0.44	1024	768	cf2f7e5e8a63f8b6793db295c7f998718a2f282b927e70920fdd38a97afb51a6
627	2024-11-28 06:57:09.114178+00	2024-11-28 06:57:09.114178+00	\N	http://holote.vn:8083/image-storage/IMG1732777028008407524.jpeg	jpeg	0.30	768	1024	0aba6a03ec3866bc2eb75b80e30a3d54b904a95e75ded4e070fd1e561f071546
628	2024-11-28 06:57:19.396347+00	2024-11-28 06:57:19.396347+00	\N	http://holote.vn:8083/image-storage/IMG1732777038290407120.jpeg	jpeg	0.42	1024	768	31bdb8901f6e2bfd9116790c863058e0bfc542a790cb82f0bb46e4ea63f85f0b
629	2024-11-28 06:59:20.835562+00	2024-11-28 06:59:20.835562+00	\N	http://holote.vn:8083/image-storage/IMG1732777159730297340.jpeg	jpeg	0.26	768	1024	36d1c48bedade1127fffc1682520f949c55e99522aacc4f1fa480af477ba7787
630	2024-11-28 07:00:10.50918+00	2024-11-28 07:00:10.50918+00	\N	http://holote.vn:8083/image-storage/IMG1732777209402193501.jpeg	jpeg	0.53	1024	768	fe9512dc1f05b2217461aef36120ad888a5560e6f9150595a03434f72abc1668
631	2024-11-28 07:24:39.549021+00	2024-11-28 07:24:39.549021+00	\N	http://holote.vn:8083/image-storage/IMG1732778678438797692.jpeg	jpeg	0.52	1024	768	68c22382ff903838c672b6b65f47d3fe4623e6cab2efe2763ea0d9b4a79991cd
632	2024-11-28 07:25:09.8875+00	2024-11-28 07:25:09.8875+00	\N	http://holote.vn:8083/image-storage/IMG1732778708778338535.jpeg	jpeg	0.46	1024	768	15e53c9751dafb7f4866ab8638a947b6cb3afd4009d1ce249273d3e1e7067779
633	2024-11-28 07:26:46.894715+00	2024-11-28 07:26:46.894715+00	\N	http://holote.vn:8083/image-storage/IMG1732778805785334280.jpeg	jpeg	0.46	1024	768	4d3d08238b77fcacbaac7d5650e7a7ad6711bf74da43362e564924f7f415094e
634	2024-11-28 07:27:40.547751+00	2024-11-28 07:27:40.547751+00	\N	http://holote.vn:8083/image-storage/IMG1732778859437450444.jpeg	jpeg	0.50	1024	768	1ffe8a35f6157cffbaf3c7cdf4af17d9727db0bf677e2f8f8cf472454b103492
635	2024-11-28 07:42:08.703484+00	2024-11-28 07:42:08.703484+00	\N	http://holote.vn:8083/image-storage/IMG1732779727591019488.jpeg	jpeg	0.55	1024	768	4ae773ace759731e0d01df23bc30e98d23bec73f84adea3d55afe6d3f43a36e5
636	2024-11-28 07:42:26.029264+00	2024-11-28 07:42:26.029264+00	\N	http://holote.vn:8083/image-storage/IMG1732779744918064993.jpeg	jpeg	0.49	1024	768	0d25df34b31d5484c116238a50330e3245de8ef79d21183754f033a4a1d93cff
637	2024-11-28 07:57:04.63214+00	2024-11-28 07:57:04.63214+00	\N	http://holote.vn:8083/image-storage/IMG1732780623518987519.jpeg	jpeg	0.47	1024	768	ddb8ab912de8e6a3216dd3b35724b34569cd2502ccebf048deb70fe5580b514e
638	2024-11-28 07:57:54.543798+00	2024-11-28 07:57:54.543798+00	\N	http://holote.vn:8083/image-storage/IMG1732780673427753468.jpeg	jpeg	0.47	1024	768	946d4ebb3f16d5a3792bd4d8d415904a619c2a41b4662a58c1f92913ec519bd6
639	2024-11-28 08:28:54.105375+00	2024-11-28 08:28:54.105375+00	\N	http://holote.vn:8083/image-storage/IMG1732782532988119290.jpeg	jpeg	0.44	1024	768	251d37c65f82688d7b0912443a56d101ca0afcf09db56e93d1e66d75d183f5cc
640	2024-11-28 08:29:19.688494+00	2024-11-28 08:29:19.688494+00	\N	http://holote.vn:8083/image-storage/IMG1732782558571597965.jpeg	jpeg	0.49	1024	768	efa7f6674875cd4c9e715f049d5f045e5eea5a1c3cedc0951fe09d2fc65f2942
641	2024-11-28 08:29:39.342803+00	2024-11-28 08:29:39.342803+00	\N	http://holote.vn:8083/image-storage/IMG1732782578225734550.jpeg	jpeg	0.48	1024	768	b93a5f06f215dd237160d3a94c71150b378ad548fd34e73d4f2c3db1b843e443
642	2024-11-28 08:29:58.240441+00	2024-11-28 08:29:58.240441+00	\N	http://holote.vn:8083/image-storage/IMG1732782597122407796.jpeg	jpeg	0.48	1024	768	30f2798fc64c2809d1b6379a0741dc2ab68955c4e08dc0b6ce10f2949b3765ea
643	2024-11-28 08:31:02.413149+00	2024-11-28 08:31:02.413149+00	\N	http://holote.vn:8083/image-storage/IMG1732782661296067389.jpeg	jpeg	0.48	1024	768	44dce376e785cb239cf3ec5cc14011fae7eb23af398196e4116cf59b8a11ea4b
644	2024-11-28 08:31:46.467748+00	2024-11-28 08:31:46.467748+00	\N	http://holote.vn:8083/image-storage/IMG1732782705351724338.jpeg	jpeg	0.24	768	1024	a4ba9e3e9cef6deb0efc57194f9763c674791360fdcf509a1659db0ef684be89
645	2024-11-28 08:33:55.871651+00	2024-11-28 08:33:55.871651+00	\N	http://holote.vn:8083/image-storage/IMG1732782834755148647.jpeg	jpeg	0.25	768	1024	a24504b36ee6ea07aa0d256f88fd162268c7f644794f0d7075ef546b1b056944
646	2024-11-28 08:35:13.046692+00	2024-11-28 08:35:13.046692+00	\N	http://holote.vn:8083/image-storage/IMG1732782911929398759.jpeg	jpeg	0.50	1024	768	a281d780619b9991634fffa166fd3ba7c547895648f3e8645ceeaba5b6a901d4
647	2024-11-28 08:36:00.433626+00	2024-11-28 08:36:00.433626+00	\N	http://holote.vn:8083/image-storage/IMG1732782959315868490.jpeg	jpeg	0.47	1024	768	f8118fcd6364ca28992ead4cfe76b7d0aec202264983ca0c8d1d0ded8de5c7b5
648	2024-11-28 08:36:18.365955+00	2024-11-28 08:36:18.365955+00	\N	http://holote.vn:8083/image-storage/IMG1732782977248316835.jpeg	jpeg	0.47	1024	768	6f52800d8af8c24ca70e8e215714699dd672a32750826889466fae043c16665e
649	2024-11-28 08:40:35.043675+00	2024-11-28 08:40:35.043675+00	\N	http://holote.vn:8083/image-storage/IMG1732783233924579630.jpeg	jpeg	0.47	1024	768	e66cf490f151a6e54fd4d2d0e7741eabfd5f6b62e9c822d14076e8bc48a15abe
650	2024-11-28 08:41:52.589053+00	2024-11-28 08:41:52.589053+00	\N	http://holote.vn:8083/image-storage/IMG1732783311470712824.jpeg	jpeg	0.53	1024	768	df51c75c1b58033e9d6c6196eb9e8f156f441df8c5451932310cdd85ec7a2f47
651	2024-11-28 08:49:51.460741+00	2024-11-28 08:49:51.460741+00	\N	http://holote.vn:8083/image-storage/IMG1732783790339423826.jpeg	jpeg	0.50	1024	768	8c5071f5f13a307a275bcea6ce39c6a585b9efbcc6e9cfda14a1aa2e162a2ff5
652	2024-11-28 08:50:10.845253+00	2024-11-28 08:50:10.845253+00	\N	http://holote.vn:8083/image-storage/IMG1732783809726187777.jpeg	jpeg	0.48	1024	768	97b61829c569e90f0124b217536cb0c12c3cf407e1698c7728806ac78c96be24
653	2024-11-28 08:50:42.409069+00	2024-11-28 08:50:42.409069+00	\N	http://holote.vn:8083/image-storage/IMG1732783841289891033.jpeg	jpeg	0.50	1024	768	bd498c9c972321a306724fd50b479998c570e0da44fdb37c855d67eb0c56d422
654	2024-11-28 08:51:02.684627+00	2024-11-28 08:51:02.684627+00	\N	http://holote.vn:8083/image-storage/IMG1732783861566538294.jpeg	jpeg	0.27	768	1024	6981bff26d7ce71a10b390f0740b1e488cec18bd8139379d3d41fd6cc45bf9ee
655	2024-11-28 08:52:38.542384+00	2024-11-28 08:52:38.542384+00	\N	http://holote.vn:8083/image-storage/IMG1732783957422081411.jpeg	jpeg	0.50	1024	768	d60b617e277185a9a28bd2d04432fcf2dc60d86dbbf42dbb668885b0f9dd4da2
656	2024-11-28 08:53:00.707342+00	2024-11-28 08:53:00.707342+00	\N	http://holote.vn:8083/image-storage/IMG1732783979587689875.jpeg	jpeg	0.45	1024	768	288f71ad3222ff02af62690d1ad3f5515f22d0022b0898a6901dcca908005e45
657	2024-11-28 08:58:56.427865+00	2024-11-28 08:58:56.427865+00	\N	http://holote.vn:8083/image-storage/IMG1732784335308770876.jpeg	jpeg	0.43	1024	768	11ef0b50b89dc34aea86fdd04bcafc5fe88a8a4aa1ea7431d0c960af0e309a31
658	2024-11-28 08:59:27.848631+00	2024-11-28 08:59:27.848631+00	\N	http://holote.vn:8083/image-storage/IMG1732784366728025193.jpeg	jpeg	0.45	1024	768	5c344f3e473e6508068f7d4389c951300d412ff980c04156f31306494fc55ee3
659	2024-11-28 08:59:48.457431+00	2024-11-28 08:59:48.457431+00	\N	http://holote.vn:8083/image-storage/IMG1732784387336617319.jpeg	jpeg	0.26	768	1024	c436812b5f8a9e219d88ac9664483d1ea1462ca2c626f26bb2967626d473477a
660	2024-11-28 09:00:08.716088+00	2024-11-28 09:00:08.716088+00	\N	http://holote.vn:8083/image-storage/IMG1732784407596193099.jpeg	jpeg	0.46	1024	768	57b9f2f06cc81e4ef58a0667f7e93050407ad375d6eaa9ef6a06ed1d383a2600
661	2024-11-28 09:01:20.69084+00	2024-11-28 09:01:20.69084+00	\N	http://holote.vn:8083/image-storage/IMG1732784479570448333.jpeg	jpeg	0.47	1024	768	2ce6941b897a279a3d7ca4e8e17956d52fba3e05cc13d041b940dbcd4c170b86
662	2024-11-28 09:01:42.928616+00	2024-11-28 09:01:42.928616+00	\N	http://holote.vn:8083/image-storage/IMG1732784501807885848.jpeg	jpeg	0.45	1024	768	5ac9ad5bd825690b96f8494760f23db4fca70547f168a82bf3e86567892ca999
663	2024-11-28 09:04:16.489911+00	2024-11-28 09:04:16.489911+00	\N	http://holote.vn:8083/image-storage/IMG1732784655369597019.jpeg	jpeg	0.45	1024	768	5b423013e2a0438c6a3f812231400ff22a81ba4963f7d00620a280b0ec0d256e
664	2024-11-28 09:04:34.889349+00	2024-11-28 09:04:34.889349+00	\N	http://holote.vn:8083/image-storage/IMG1732784673768572122.jpeg	jpeg	0.47	1024	768	4bf7b44545e045ff32eab39a0582e69ef86e59494c30784016ce9d56c83ba13a
665	2024-11-28 09:04:52.36798+00	2024-11-28 09:04:52.36798+00	\N	http://holote.vn:8083/image-storage/IMG1732784691245612205.jpeg	jpeg	0.47	1024	768	d61ac967e65cd40bdce33c33ead1bbe827d49e7e59e302a1912c544e7e99fb89
666	2024-11-28 09:05:12.008179+00	2024-11-28 09:05:12.008179+00	\N	http://holote.vn:8083/image-storage/IMG1732784710887752048.jpeg	jpeg	0.45	1024	768	5fb56c91f4b28a21e9e31a6d25f4a12e0cd79fc7cad2afadf3a91556e6f002d4
667	2024-11-28 09:06:39.037862+00	2024-11-28 09:06:39.037862+00	\N	http://holote.vn:8083/image-storage/IMG1732784797899985621.jpeg	jpeg	0.38	1024	768	688ff77559ca798df5850427b1ba6b19ee015481d42d3c98eca6025a59815d96
668	2024-11-28 09:06:56.933522+00	2024-11-28 09:06:56.933522+00	\N	http://holote.vn:8083/image-storage/IMG1732784815813119116.jpeg	jpeg	0.40	1024	768	e0d5ba2567ae0b2bcb2c4a715806f57d3572fcef6167569f3be40ad2eeff7e7a
669	2024-11-29 02:13:31.048503+00	2024-11-29 02:13:31.048503+00	\N	http://holote.vn:8083/image-storage/IMG1732846409809658344.jpeg	jpeg	0.52	1024	768	986427df051d7c833c616efc8b978a28b6f6ecf25dd5c756f68259810742bcaa
670	2024-11-29 02:13:48.992262+00	2024-11-29 02:13:48.992262+00	\N	http://holote.vn:8083/image-storage/IMG1732846427753291334.jpeg	jpeg	0.50	1024	768	cd1c6be1296b53af8d66410aac2ec5840874b3fce937e1178c1e56861d67d701
671	2024-11-29 02:14:32.837367+00	2024-11-29 02:14:32.837367+00	\N	http://holote.vn:8083/image-storage/IMG1732846471599692295.jpeg	jpeg	0.24	768	1024	58044e245b61dde8402ce22c27df9263f2e66d9caca27e22f11acc140e312df9
672	2024-11-29 02:14:50.06812+00	2024-11-29 02:14:50.06812+00	\N	http://holote.vn:8083/image-storage/IMG1732846488830254629.jpeg	jpeg	0.28	768	1024	3ad6ae8d549b54b8a06e0faf5e73155791561845921c8378896889050ebaca98
673	2024-11-29 03:13:45.586967+00	2024-11-29 03:13:45.586967+00	\N	http://holote.vn:8083/image-storage/IMG1732850024340997519.jpeg	jpeg	0.50	1024	768	2f0ee1d70e64a74b4b9ee7ccbf1ad85b247bbd36b3130be02ec5d711addf955c
674	2024-11-29 03:14:05.615844+00	2024-11-29 03:14:05.615844+00	\N	http://holote.vn:8083/image-storage/IMG1732850044370461346.jpeg	jpeg	0.49	1024	768	1fad69bf140e857d958bb4d07de8c74e524db491f8891bddf76e11db19cdfed4
675	2024-11-29 04:18:30.854608+00	2024-11-29 04:18:30.854608+00	\N	http://holote.vn:8083/image-storage/IMG1732853909601156027.jpeg	jpeg	0.47	1024	768	666c8f69a3657131199ed849ac670f28ea46bac825bd5630f70fa3b236653dd0
676	2024-11-29 04:18:50.683222+00	2024-11-29 04:18:50.683222+00	\N	http://holote.vn:8083/image-storage/IMG1732853929429768438.jpeg	jpeg	0.49	1024	768	4ff8402813a2e171f388dad75a2c80cae145e70c4af312d4b311afe7c0027eab
677	2024-11-29 06:52:01.404418+00	2024-11-29 06:52:01.404418+00	\N	http://holote.vn:8083/image-storage/IMG1732863120133537942.jpeg	jpeg	0.50	1024	768	5f92684ef896114aa6b72508e03af074a5cf0923e1c51efb4371e76549b3c22b
678	2024-11-29 06:52:18.815391+00	2024-11-29 06:52:18.815391+00	\N	http://holote.vn:8083/image-storage/IMG1732863137543733000.jpeg	jpeg	0.50	1024	768	fa310aa78f3932fdfe918e4b6f8cd7a77b1fd10e691d3de5d40fa047d00671a2
679	2024-11-29 06:53:10.362356+00	2024-11-29 06:53:10.362356+00	\N	http://holote.vn:8083/image-storage/IMG1732863189091102822.jpeg	jpeg	0.50	1024	768	445d86c2b87a26797ed92e2f8e303b60c45c2e8a3ba10181eaf28fab418c73f2
680	2024-11-29 06:53:28.582251+00	2024-11-29 06:53:28.582251+00	\N	http://holote.vn:8083/image-storage/IMG1732863207312825294.jpeg	jpeg	0.26	768	1024	363704bd4da4ae83ca2a0a09e06fbafb3d0a25f1d89368a8eb699e9522ff834f
681	2024-11-29 06:55:02.773159+00	2024-11-29 06:55:02.773159+00	\N	http://holote.vn:8083/image-storage/IMG1732863301500867259.jpeg	jpeg	0.49	1024	768	767239673bfe6f24aba959678def6263a41570c3025cd9d352c7394fa82a1220
682	2024-11-29 06:55:21.189956+00	2024-11-29 06:55:21.189956+00	\N	http://holote.vn:8083/image-storage/IMG1732863319917413603.jpeg	jpeg	0.49	1024	768	1bfdf3ee0a62066cc980246a31f7577f11dad66cce519caddaa5e8ad17016bf8
683	2024-11-29 07:10:05.807904+00	2024-11-29 07:10:05.807904+00	\N	http://holote.vn:8083/image-storage/IMG1732864204535630257.jpeg	jpeg	0.42	1024	768	6bd1ffeb021136a74cfd57c134c344509dffb834cc7ec645860671d6e01bef3b
684	2024-11-29 07:10:25.295797+00	2024-11-29 07:10:25.295797+00	\N	http://holote.vn:8083/image-storage/IMG1732864224023259028.jpeg	jpeg	0.43	1024	768	54deaaf15faf657defb06f52fd2566c163ba22d3fcd873831e07ab41e9c33ddf
685	2024-11-29 07:11:09.51952+00	2024-11-29 07:11:09.51952+00	\N	http://holote.vn:8083/image-storage/IMG1732864268245443161.jpeg	jpeg	0.46	1024	768	e7a9f53a74d2ccdfd99fc2a3407737e957b6b9d1f45b67c0ee429eea4c483a99
686	2024-11-29 07:11:26.97178+00	2024-11-29 07:11:26.97178+00	\N	http://holote.vn:8083/image-storage/IMG1732864285698485090.jpeg	jpeg	0.49	1024	768	0f73a21bb6016006d5544a48e0beef8dec27f563bb50911f1cf07700e546a879
687	2024-11-29 07:12:50.627732+00	2024-11-29 07:12:50.627732+00	\N	http://holote.vn:8083/image-storage/IMG1732864369354957016.jpeg	jpeg	0.47	1024	768	0529401a7b59e9b7ce8d7e134c34c86e1c8251aada72e322275a4b6ca57fe935
688	2024-11-29 07:13:09.102129+00	2024-11-29 07:13:09.102129+00	\N	http://holote.vn:8083/image-storage/IMG1732864387826577232.jpeg	jpeg	0.45	1024	768	4b29e14742cb01db535263ffe113b5869f2f40dd95d9de00dc5b517398239971
689	2024-11-29 08:33:32.321019+00	2024-11-29 08:33:32.321019+00	\N	http://holote.vn:8083/image-storage/IMG1732869211036304138.jpeg	jpeg	0.47	1024	768	f0a5047c84749cb59b90dacba895c291f2edde0a1fe0192e41fd0a13c554f801
690	2024-11-29 08:33:52.314183+00	2024-11-29 08:33:52.314183+00	\N	http://holote.vn:8083/image-storage/IMG1732869231029914329.jpeg	jpeg	0.48	1024	768	63549c5f6f7bde1e8605ccc0069815cec1c49728642dfc35ade386098a390d57
691	2024-11-30 21:58:17.584743+00	2024-11-30 21:58:17.584743+00	\N	http://holote.vn:8083/image-storage/IMG1733003896050937852.jpeg	jpeg	0.03	768	1024	099b8a5b9b4e430c237cac895fca13c00f046e06c9ff98cf843ce2b1627bb9d3
692	2024-11-30 21:59:20.398839+00	2024-11-30 21:59:20.398839+00	\N	http://holote.vn:8083/image-storage/IMG1733003958861630136.jpeg	jpeg	0.02	1024	768	e775101de62ebb32110e1334d4c7b145dfd81f42d40365de4e6bb616429356a2
693	2024-11-30 21:59:20.527653+00	2024-11-30 21:59:20.527653+00	\N	http://holote.vn:8083/image-storage/IMG1733003958861630089.jpeg	jpeg	0.03	1024	768	4c4fabdff1187632a5333090e3003b6d94af1edf45bdcb21edf5595df5673133
694	2024-11-30 22:08:25.192193+00	2024-11-30 22:08:25.192193+00	\N	http://holote.vn:8083/image-storage/IMG1733004503657847252.jpeg	jpeg	0.03	768	1024	5068dbaba1af70f47cf5a92c64410145ae6201f33621bc62810ab6e8c2c2884b
695	2024-11-30 22:09:34.838896+00	2024-11-30 22:09:34.838896+00	\N	http://holote.vn:8083/image-storage/IMG1733004573304917735.jpeg	jpeg	0.02	1024	768	1c98eed373990732e5037177d4f29eae4b8f4274e979b250ef0e5d86f1a91157
696	2024-11-30 22:09:34.839583+00	2024-11-30 22:09:34.839583+00	\N	http://holote.vn:8083/image-storage/IMG1733004573304912040.jpeg	jpeg	0.02	1024	768	1c98eed373990732e5037177d4f29eae4b8f4274e979b250ef0e5d86f1a91157
697	2024-11-30 23:24:12.781688+00	2024-11-30 23:24:12.781688+00	\N	http://holote.vn:8083/image-storage/IMG1733009051236393616.jpeg	jpeg	0.45	1024	768	1eb03a53d2cd4bc7f56a0bb73fb5f503e25f3c3aeb4c332ab23ff83652101544
698	2024-11-30 23:33:09.793257+00	2024-11-30 23:33:09.793257+00	\N	http://holote.vn:8083/image-storage/IMG1733009588246329111.jpeg	jpeg	0.30	1024	768	7cf0234ecaeadcd9f60355cbc454a399fc1359fc6fe6046a9e9df7f9f5baa2dd
699	2024-12-01 01:41:58.615714+00	2024-12-01 01:41:58.615714+00	\N	http://holote.vn:8083/image-storage/IMG1733017317052850440.jpeg	jpeg	0.48	1024	768	04e1e26f8750146d7b3c4cde68292e224826d9ceeac9d1ab84c649f61a840a64
700	2024-12-01 01:42:20.943853+00	2024-12-01 01:42:20.943853+00	\N	http://holote.vn:8083/image-storage/IMG1733017339382959420.jpeg	jpeg	0.48	1024	768	50ccf27df28237271d146c22c1a4bf0b2f1c6cf6c0d53f9e4d2655ea1cbf2892
701	2024-12-01 01:47:21.163446+00	2024-12-01 01:47:21.163446+00	\N	http://holote.vn:8083/image-storage/IMG1733017639601245626.jpeg	jpeg	0.47	1024	768	00bdf74f073a3f16af9acd5205ff4794b0a7adfcfcc38bdff025d8cc74b2e143
702	2024-12-01 03:19:48.100844+00	2024-12-01 03:19:48.100844+00	\N	http://holote.vn:8083/image-storage/IMG1733023186527401034.jpeg	jpeg	0.45	1024	768	01010d0bf9a6ab2f78a1d2dda38f30696523a2b57dd269ca5b3dbd8e26835de4
703	2024-12-01 03:20:50.65257+00	2024-12-01 03:20:50.65257+00	\N	http://holote.vn:8083/image-storage/IMG1733023249079436595.jpeg	jpeg	0.46	1024	768	54a755d7777ea93a0b197ff811563493cb670bbd583032af2722536b1e28bf4d
704	2024-12-01 03:36:14.04216+00	2024-12-01 03:36:14.04216+00	\N	http://holote.vn:8083/image-storage/IMG1733024172468086937.jpeg	jpeg	0.45	1024	768	3d8f321f0f18bc1a8f2f41ceb92d3a2def68092f08450ee92a80af36803b6f65
705	2024-12-01 03:36:47.811137+00	2024-12-01 03:36:47.811137+00	\N	http://holote.vn:8083/image-storage/IMG1733024206236360410.jpeg	jpeg	0.48	1024	768	5af2265f79c9167d36a23df289012cfc28c37171bd6a2eb93d9dc041f11d0101
706	2024-12-01 03:37:16.493841+00	2024-12-01 03:37:16.493841+00	\N	http://holote.vn:8083/image-storage/IMG1733024234919671240.jpeg	jpeg	0.44	1024	768	eab35af89e9fc40bcc9eebab30bdda2c7326823251bb6df0864fdcffc8aa1af0
707	2024-12-01 03:37:50.211177+00	2024-12-01 03:37:50.211177+00	\N	http://holote.vn:8083/image-storage/IMG1733024268636656505.jpeg	jpeg	0.46	1024	768	06a6823ec759f59a6ace0e2cc740c98ac7e17fc58c967c3385033765805ac91b
708	2024-12-01 03:39:21.092463+00	2024-12-01 03:39:21.092463+00	\N	http://holote.vn:8083/image-storage/IMG1733024359517232533.jpeg	jpeg	0.46	1024	768	c7d06fa760296baa3148f9652767b0a6db8fd8fca45214cd36bbb24a14d7dc77
709	2024-12-01 03:40:10.019542+00	2024-12-01 03:40:10.019542+00	\N	http://holote.vn:8083/image-storage/IMG1733024408444415756.jpeg	jpeg	0.46	1024	768	85bc2b16510eb0d370439b6eb37bb0ab31916b2f0df56d627afca23ccd4291b9
710	2024-12-01 03:47:16.434664+00	2024-12-01 03:47:16.434664+00	\N	http://holote.vn:8083/image-storage/IMG1733024834858326727.jpeg	jpeg	0.47	1024	768	a83db9732ea85e0d78905dcfec2cfa15fea598f04e7ad942736cd0f73df6f6f6
711	2024-12-01 03:54:17.663915+00	2024-12-01 03:54:17.663915+00	\N	http://holote.vn:8083/image-storage/IMG1733025256087589845.jpeg	jpeg	0.44	1024	768	ab3e6b47d83a4580a772676293484a61df1b19e26ea6efbc0cf3bd822c45f695
712	2024-12-01 03:54:41.309789+00	2024-12-01 03:54:41.309789+00	\N	http://holote.vn:8083/image-storage/IMG1733025279733149501.jpeg	jpeg	0.44	1024	768	6291f80d699ea6eb4c7d1cd9c678004548525f4b1c4f09e594bd3828342b7010
713	2024-12-01 03:59:43.038763+00	2024-12-01 03:59:43.038763+00	\N	http://holote.vn:8083/image-storage/IMG1733025581462313087.jpeg	jpeg	0.03	768	1024	19bee85de651814b4c6e18e735e530abaf9ccf1d40d5146dc7f8d99aee9224fa
714	2024-12-01 04:55:58.31481+00	2024-12-01 04:55:58.31481+00	\N	http://holote.vn:8083/image-storage/IMG1733028956729854573.jpeg	jpeg	0.45	1024	768	dd4b87e29e92f6ec79239c3bc2b994d0d3e0912a94e194cdaf8fdb3e0879f8b4
715	2024-12-01 04:56:17.857321+00	2024-12-01 04:56:17.857321+00	\N	http://holote.vn:8083/image-storage/IMG1733028976271902855.jpeg	jpeg	0.45	1024	768	6dca7cbab5f434b7639d47d59d278fd0c58983f940407e5fd7968ed5f85860eb
716	2024-12-01 04:56:42.245956+00	2024-12-01 04:56:42.245956+00	\N	http://holote.vn:8083/image-storage/IMG1733029000661058668.jpeg	jpeg	0.46	1024	768	f297a3ea05581b6b3a309031885ee26230610412659cac42ffa7155d4438c657
717	2024-12-01 04:57:01.730586+00	2024-12-01 04:57:01.730586+00	\N	http://holote.vn:8083/image-storage/IMG1733029020145762812.jpeg	jpeg	0.47	1024	768	281d1465cc5f5281d38f87f164d2ad39a219f9e87474c52eb4433eba90dd8f4a
718	2024-12-01 04:57:52.622089+00	2024-12-01 04:57:52.622089+00	\N	http://holote.vn:8083/image-storage/IMG1733029071037429476.jpeg	jpeg	0.45	1024	768	ec66f1cd0395c0cb728c882b501347777afd03b56c0e68fc44852d171c0c9083
719	2024-12-01 04:58:30.343416+00	2024-12-01 04:58:30.343416+00	\N	http://holote.vn:8083/image-storage/IMG1733029108758483434.jpeg	jpeg	0.44	1024	768	9addd98d3fb6c3366a42688c228b73b74b1e298301f1457296e63a99b46d0330
720	2024-12-01 04:59:05.159018+00	2024-12-01 04:59:05.159018+00	\N	http://holote.vn:8083/image-storage/IMG1733029143574029356.jpeg	jpeg	0.45	1024	768	1b4be4db63fa69a2067a75bffb576a541cde86bbc03d6d796afef09adcabba72
721	2024-12-01 05:00:37.618917+00	2024-12-01 05:00:37.618917+00	\N	http://holote.vn:8083/image-storage/IMG1733029236034505860.jpeg	jpeg	0.45	1024	768	dcc2b0d4d108a6e6a2545a34a938bde181819cf85e5cb502d7580a22b7b817b4
722	2024-12-01 05:01:13.415826+00	2024-12-01 05:01:13.415826+00	\N	http://holote.vn:8083/image-storage/IMG1733029271830906454.jpeg	jpeg	0.45	1024	768	335344ec89403f7425e456d993e494ee66b1018ef33ebafa00cbf9dfc26e2b61
723	2024-12-01 05:01:35.816239+00	2024-12-01 05:01:35.816239+00	\N	http://holote.vn:8083/image-storage/IMG1733029294229135752.jpeg	jpeg	0.45	1024	768	b25f743ea202d9963d4a9326580aa40fb7571f6f7fdf436f65feea150c4e2c6b
724	2024-12-01 05:55:35.698737+00	2024-12-01 05:55:35.698737+00	\N	http://holote.vn:8083/image-storage/IMG1733032534106781115.jpeg	jpeg	0.43	1024	768	6ea80c4bc5375d9ffa45cb4eeab4ee60f6f0c7efb3f86da6e30894dc72297a02
725	2024-12-01 05:56:07.965569+00	2024-12-01 05:56:07.965569+00	\N	http://holote.vn:8083/image-storage/IMG1733032566374404501.jpeg	jpeg	0.43	1024	768	085fcd7200f07b46abbed85094745088d7e93c54f0631d1b650dabcaa845c850
726	2024-12-01 05:57:17.966488+00	2024-12-01 05:57:17.966488+00	\N	http://holote.vn:8083/image-storage/IMG1733032636376792458.jpeg	jpeg	0.03	768	1024	9edda890ca51ef2508f157f3a53d9edfad5373751b3a7bcd6fa9bdd772d5899c
727	2024-12-01 05:57:40.031424+00	2024-12-01 05:57:40.031424+00	\N	http://holote.vn:8083/image-storage/IMG1733032658441918235.jpeg	jpeg	0.03	768	1024	135b83997fee857c016737b1039287a9edcb5dab0bb90b1a4e0b4c15260730bb
728	2024-12-01 05:58:07.026903+00	2024-12-01 05:58:07.026903+00	\N	http://holote.vn:8083/image-storage/IMG1733032685437599765.jpeg	jpeg	0.02	768	1024	05aaeac2f93102dd0b46eeeabe0032c239c641fe3b0100a37aa2628d61df8e50
729	2024-12-01 05:58:42.357115+00	2024-12-01 05:58:42.357115+00	\N	http://holote.vn:8083/image-storage/IMG1733032720767859416.jpeg	jpeg	0.03	768	1024	6bd9cefa3eeaeaeeefbff5592f04109ea0447356054a9c0bda9213f84e1104a2
730	2024-12-01 05:59:29.536161+00	2024-12-01 05:59:29.536161+00	\N	http://holote.vn:8083/image-storage/IMG1733032767946508280.jpeg	jpeg	0.03	768	1024	64a0f4febcc0d1e6ad3594ef8d1ce733b033858bbe2ea2c1d0c8e04e51f36ece
731	2024-12-01 05:59:52.251692+00	2024-12-01 05:59:52.251692+00	\N	http://holote.vn:8083/image-storage/IMG1733032790662180278.jpeg	jpeg	0.03	768	1024	f5c8a04c71763d03d6d23c66184cef55b9f105139b703adb0629e9281527c5dd
732	2024-12-01 08:27:54.561947+00	2024-12-01 08:27:54.561947+00	\N	http://holote.vn:8083/image-storage/IMG1733041672954117929.jpeg	jpeg	0.03	768	1024	45c692de2fe71a58bc3d7e4bde86d43311b29539cd197f6b426b9d5c67b50b6a
733	2024-12-02 00:28:48.118817+00	2024-12-02 00:28:48.118817+00	\N	http://holote.vn:8083/image-storage/IMG1733099326405999434.jpeg	jpeg	0.03	768	1024	0226b0e340749103e410de5fd16e5ba36594773b2c18d0fb250b4f8a33bff70d
734	2024-12-02 00:31:54.263688+00	2024-12-02 00:31:54.263688+00	\N	http://holote.vn:8083/image-storage/IMG1733099512550562796.jpeg	jpeg	0.03	768	1024	710d1b7bb4100d0bd668ff2ae26fa700ca52b72f3647e1a266d7e1132f341ceb
735	2024-12-02 00:43:02.993114+00	2024-12-02 00:43:02.993114+00	\N	http://holote.vn:8083/image-storage/IMG1733100181278961264.jpeg	jpeg	0.03	768	1024	2c805c20da70bc19340a34b697944fe9703fd259626345e546c79703fdd0963e
736	2024-12-02 00:43:59.475328+00	2024-12-02 00:43:59.475328+00	\N	http://holote.vn:8083/image-storage/IMG1733100237761107749.jpeg	jpeg	0.02	768	1024	74ef1bd66b6ec29813e5532a8ca9243826cd65b9914754e5a018fd157ee9d805
737	2024-12-02 00:52:49.50427+00	2024-12-02 00:52:49.50427+00	\N	http://holote.vn:8083/image-storage/IMG1733100767788893387.jpeg	jpeg	0.03	768	1024	eebf93f6b0ca18e7285b8369df792090979963f9298dc6bf49695fadca723247
738	2024-12-02 00:53:18.040037+00	2024-12-02 00:53:18.040037+00	\N	http://holote.vn:8083/image-storage/IMG1733100796324962130.jpeg	jpeg	0.03	768	1024	7f42b5d8fc4feca4fa776a4f669d1b8d3d23ff705b4a9ef1567451e1bae20225
739	2024-12-02 00:54:57.896754+00	2024-12-02 00:54:57.896754+00	\N	http://holote.vn:8083/image-storage/IMG1733100896178208836.jpeg	jpeg	0.51	1024	768	b6e2fd0e0ea693e1960ee390d2be452eece45c9c98ce497445634503dc99a429
740	2024-12-02 01:09:34.173776+00	2024-12-02 01:09:34.173776+00	\N	http://holote.vn:8083/image-storage/IMG1733101772455515772.jpeg	jpeg	0.03	768	1024	5cdbce8b261de620452d5959556ee1fd7d5259d3cf94f2eb1a7b58fb25bf6ac2
741	2024-12-02 01:10:10.445343+00	2024-12-02 01:10:10.445343+00	\N	http://holote.vn:8083/image-storage/IMG1733101808728364870.jpeg	jpeg	0.03	768	1024	f5a59f25c541c02fae71367edc5328549209a9cec4be959e0b06466699f89451
742	2024-12-02 01:21:46.565106+00	2024-12-02 01:21:46.565106+00	\N	http://holote.vn:8083/image-storage/IMG1733102504846177593.jpeg	jpeg	0.02	768	1024	e590643a5817b75129de1116f135731a551d0d737a6602a0e65b249eda26ca16
743	2024-12-02 01:42:34.930653+00	2024-12-02 01:42:34.930653+00	\N	http://holote.vn:8083/image-storage/IMG1733103753209631989.jpeg	jpeg	0.03	768	1024	f33edf339713e59a73fcf8bd289e4316e2481e4cb553ab2f1a4fc6e19bd741fd
744	2024-12-02 02:03:01.198048+00	2024-12-02 02:03:01.198048+00	\N	http://holote.vn:8083/image-storage/IMG1733104979475098654.jpeg	jpeg	0.03	768	1024	b6124f7eb108b986303702a63e61795419be61ee37ed932650099ff361964bcb
745	2024-12-02 02:06:00.259481+00	2024-12-02 02:06:00.259481+00	\N	http://holote.vn:8083/image-storage/IMG1733105158536540038.jpeg	jpeg	0.03	768	1024	6b1638afc964bc3411b970e3b3735ddf200fc9cf9fa0d914a153a70ba7e06f95
746	2024-12-02 02:07:52.41932+00	2024-12-02 02:07:52.41932+00	\N	http://holote.vn:8083/image-storage/IMG1733105270696227870.jpeg	jpeg	0.02	768	1024	48cf49227286987f79a06bdddabb22939452a0660b5a40e6226be158fc399bd7
747	2024-12-02 02:09:23.082476+00	2024-12-02 02:09:23.082476+00	\N	http://holote.vn:8083/image-storage/IMG1733105361357032002.jpeg	jpeg	0.03	768	1024	30abecb72f6acd9ed1f8fd1e17fc61266f43c36f6ebcc1f61bd02224b5938a9c
748	2024-12-02 02:09:58.372219+00	2024-12-02 02:09:58.372219+00	\N	http://holote.vn:8083/image-storage/IMG1733105396648089869.jpeg	jpeg	0.03	768	1024	f806c89ef628096e225bcb6428a49fb3dd039f78a30645c925d465745014c9e7
749	2024-12-02 02:15:15.8204+00	2024-12-02 02:15:15.8204+00	\N	http://holote.vn:8083/image-storage/IMG1733105714095695013.jpeg	jpeg	0.03	768	1024	a71c25c40cef0a49f22f13ba5909ca46142177f2ac607c76947428b392209c7d
750	2024-12-02 02:17:20.954687+00	2024-12-02 02:17:20.954687+00	\N	http://holote.vn:8083/image-storage/IMG1733105839229848349.jpeg	jpeg	0.03	768	1024	e8b55c15c7628b8d86793d37c83c041554f3db5919e233fc94e9056d2866ec88
751	2024-12-02 02:18:05.202543+00	2024-12-02 02:18:05.202543+00	\N	http://holote.vn:8083/image-storage/IMG1733105883475122042.jpeg	jpeg	0.53	1024	768	af624c848abd0c3c8c33a3ba8245570e571b74a1f64f93b6fb5a552127f68f04
752	2024-12-02 02:29:29.53567+00	2024-12-02 02:29:29.53567+00	\N	http://holote.vn:8083/image-storage/IMG1733106567809764372.jpeg	jpeg	0.03	768	1024	2de232178f632d8a8240664fcfcdc2e834f9ff47b8c0d16ff43ad0330b412771
753	2024-12-02 02:30:57.214518+00	2024-12-02 02:30:57.214518+00	\N	http://holote.vn:8083/image-storage/IMG1733106655488361571.jpeg	jpeg	0.03	768	1024	5a8b736096dad60a1fd97e371388fa8d19b726d4f8b616d3a045e5b42c6ec8af
754	2024-12-02 02:32:13.434368+00	2024-12-02 02:32:13.434368+00	\N	http://holote.vn:8083/image-storage/IMG1733106731708186737.jpeg	jpeg	0.03	768	1024	7d1f614af0248e5856ab58f74d1e86b05372ddd58a1f7354bffb5b4bf0b3650e
755	2024-12-02 02:33:08.056415+00	2024-12-02 02:33:08.056415+00	\N	http://holote.vn:8083/image-storage/IMG1733106786320770447.jpeg	jpeg	0.03	768	1024	8ca0d03b4a6203d95b611c64ebfed93a18db3da354b5ac8018a0e80798789845
756	2024-12-02 02:44:10.772101+00	2024-12-02 02:44:10.772101+00	\N	http://holote.vn:8083/image-storage/IMG1733107449044371953.jpeg	jpeg	0.03	768	1024	90a3dde80829fd2e9749aed7ebe64f3eb033c7d119c4e7dd64205f02ef0ac3ca
757	2024-12-02 02:44:38.765477+00	2024-12-02 02:44:38.765477+00	\N	http://holote.vn:8083/image-storage/IMG1733107477037666438.jpeg	jpeg	0.03	768	1024	f09d13ef4db86bcf76159a93c7d9a6c16f60f2878be2d7ee92adcf3b003ed4a3
758	2024-12-02 02:45:08.328065+00	2024-12-02 02:45:08.328065+00	\N	http://holote.vn:8083/image-storage/IMG1733107506600032122.jpeg	jpeg	0.03	768	1024	9d5fb45eaa66029d6f7215a069b742af8c3c7146b08ef400924b8ee5b6e66819
759	2024-12-02 02:45:31.851906+00	2024-12-02 02:45:31.851906+00	\N	http://holote.vn:8083/image-storage/IMG1733107530123886882.jpeg	jpeg	0.02	768	1024	13579c28dc4df57dbe65452913b4be0cb0db55e9503a2dc628a0d800910bb148
760	2024-12-02 02:46:23.451283+00	2024-12-02 02:46:23.451283+00	\N	http://holote.vn:8083/image-storage/IMG1733107581723304780.jpeg	jpeg	0.03	768	1024	2b8dcec9a6b04afe2058a1839e07041300471622ac65f36d1ac8e72105031901
761	2024-12-02 02:46:48.36434+00	2024-12-02 02:46:48.36434+00	\N	http://holote.vn:8083/image-storage/IMG1733107606636529085.jpeg	jpeg	0.03	768	1024	ac2d4b6fe05f6b185bc67c1b8fed859cd62024e6c70a2ab65ff8dbd68efaa7a1
762	2024-12-02 02:54:43.60573+00	2024-12-02 02:54:43.60573+00	\N	http://holote.vn:8083/image-storage/IMG1733108081876109705.jpeg	jpeg	0.03	768	1024	573ceb5389253c4a62e1b1eb8faf5e89e8df4154d6ec24f9b78f5f4e195d6733
763	2024-12-02 03:00:42.619035+00	2024-12-02 03:00:42.619035+00	\N	http://holote.vn:8083/image-storage/IMG1733108440889207881.jpeg	jpeg	0.03	768	1024	c072b3486b9f4b4402aa4dea275870d62ac2318322a5f9a5bcf69750b4fa9ca6
764	2024-12-02 03:05:51.975285+00	2024-12-02 03:05:51.975285+00	\N	http://holote.vn:8083/image-storage/IMG1733108750243885227.jpeg	jpeg	0.02	768	1024	ec8bcf050a0b404656dd9a0689a54f342b0c3bc1e05cccad9521a285f4a2c625
765	2024-12-02 03:06:28.097679+00	2024-12-02 03:06:28.097679+00	\N	http://holote.vn:8083/image-storage/IMG1733108786366505200.jpeg	jpeg	0.02	768	1024	cbd031e4c66564c00e7045467ea8532bbeda5579c65a4a1485ec2f587efafd21
766	2024-12-02 03:06:57.175045+00	2024-12-02 03:06:57.175045+00	\N	http://holote.vn:8083/image-storage/IMG1733108815444648701.jpeg	jpeg	0.03	768	1024	653ecfd3ef44aaed79fc070a459f11898892a60135c9805287da6f41eccd6572
767	2024-12-02 03:07:16.79598+00	2024-12-02 03:07:16.79598+00	\N	http://holote.vn:8083/image-storage/IMG1733108835064168866.jpeg	jpeg	0.03	768	1024	d52450c748c04d52f656f83e094d93b67a6e9612f4325d68607addb7133571b9
768	2024-12-02 03:07:44.034398+00	2024-12-02 03:07:44.034398+00	\N	http://holote.vn:8083/image-storage/IMG1733108862300932056.jpeg	jpeg	0.45	1024	768	d63f3309e7167c5896d55f181c8f6a830a1423b295ecf8b68487a770847ee643
769	2024-12-02 03:07:51.32593+00	2024-12-02 03:07:51.32593+00	\N	http://holote.vn:8083/image-storage/IMG1733108869595645692.jpeg	jpeg	0.03	768	1024	7b25755234819d034c70bef2eb4cd56f9c2bf13e2528ece7c2c6c499f77ec9a9
770	2024-12-02 03:08:27.910446+00	2024-12-02 03:08:27.910446+00	\N	http://holote.vn:8083/image-storage/IMG1733108906176719465.jpeg	jpeg	0.49	1024	768	c200d4040acf6f2849a65fb580e716f872a2ff9d122ba939843fbb3c94aad6b7
771	2024-12-02 03:08:32.236033+00	2024-12-02 03:08:32.236033+00	\N	http://holote.vn:8083/image-storage/IMG1733108910505621218.jpeg	jpeg	0.02	768	1024	89d5a9a3b4c3f71ab854b78be5599cfe70f4da0b2922d162b95048576ff5603f
772	2024-12-02 03:13:48.469386+00	2024-12-02 03:13:48.469386+00	\N	http://holote.vn:8083/image-storage/IMG1733109226734228681.jpeg	jpeg	0.45	1024	768	fdf573b295a8a90332b161504c929c4bbcdab69963c58380c6066349853fd13d
773	2024-12-02 03:25:08.163268+00	2024-12-02 03:25:08.163268+00	\N	http://holote.vn:8083/image-storage/IMG1733109906430205920.jpeg	jpeg	0.03	768	1024	01b67fad194d3929b72cb3670eb3311dca48de466e01c9242d78a8667339426c
774	2024-12-02 03:25:31.164728+00	2024-12-02 03:25:31.164728+00	\N	http://holote.vn:8083/image-storage/IMG1733109929431474002.jpeg	jpeg	0.03	768	1024	e7e6cb767a67a1c665f5d415fc2fb6e4fc96053a04939eff7f6dc34a2423c005
775	2024-12-02 03:26:33.984509+00	2024-12-02 03:26:33.984509+00	\N	http://holote.vn:8083/image-storage/IMG1733109992251575668.jpeg	jpeg	0.03	768	1024	65ca586159b6392f7a3cf3b941f75005c8ce0ccad532bf7e3571285c6b31c5a5
776	2024-12-02 03:35:53.978231+00	2024-12-02 03:35:53.978231+00	\N	http://holote.vn:8083/image-storage/IMG1733110552244171316.jpeg	jpeg	0.07	1024	768	406097d865f819ff8542f0d420b13de306d61052ef0307631597da1ea3ff0509
777	2024-12-02 03:38:36.950753+00	2024-12-02 03:38:36.950753+00	\N	http://holote.vn:8083/image-storage/IMG1733110715216876576.jpeg	jpeg	0.03	768	1024	7c2c29ac38adca4f3d1d3ec893a271a2c14d04726e11b5ef4150d0c7028e6946
778	2024-12-02 03:38:59.795607+00	2024-12-02 03:38:59.795607+00	\N	http://holote.vn:8083/image-storage/IMG1733110738061396557.jpeg	jpeg	0.03	768	1024	97f12d9d2d7d9ccff989bf93d3a2b8342c2e838926538ffc26f088b44e23b43e
779	2024-12-02 03:39:26.734907+00	2024-12-02 03:39:26.734907+00	\N	http://holote.vn:8083/image-storage/IMG1733110765001166617.jpeg	jpeg	0.03	768	1024	f84531380a8a6ffe6bd7f2cd3ec60a88782ae355f1af56b3b837aa79b2ec7e56
780	2024-12-02 03:39:42.542197+00	2024-12-02 03:39:42.542197+00	\N	http://holote.vn:8083/image-storage/IMG1733110780807746758.jpeg	jpeg	0.03	768	1024	53123f757e4ad7f264e570116e8ee13b9126a0de5f21923534ff108884767a70
781	2024-12-02 03:41:58.093258+00	2024-12-02 03:41:58.093258+00	\N	http://holote.vn:8083/image-storage/IMG1733110916359084293.jpeg	jpeg	0.03	768	1024	94e32e31a5784985281da0394931f8b3ad5744586d55f32eb556f46df475e2bc
782	2024-12-02 03:43:06.737913+00	2024-12-02 03:43:06.737913+00	\N	http://holote.vn:8083/image-storage/IMG1733110985003398653.jpeg	jpeg	0.03	768	1024	cbbfd23cc85dffc65763a8200039f6cea3599fa51954a8fd95b90c35b22879f0
783	2024-12-02 03:43:07.664483+00	2024-12-02 03:43:07.664483+00	\N	http://holote.vn:8083/image-storage/IMG1733110985797187345.jpeg	jpeg	0.50	1024	768	5ac21184899c1309fc28564d488b843dc0ca028d143cff29b024671ec0f89a8e
784	2024-12-02 03:43:25.803806+00	2024-12-02 03:43:25.803806+00	\N	http://holote.vn:8083/image-storage/IMG1733111004069529503.jpeg	jpeg	0.03	768	1024	301717a3e4eb1ca4eb68fb7d25199d98671c87dd882247a56993161cede815c1
785	2024-12-02 03:44:34.468845+00	2024-12-02 03:44:34.468845+00	\N	http://holote.vn:8083/image-storage/IMG1733111072734077765.jpeg	jpeg	0.03	768	1024	c1832c7d3d38a056c1f9719407aa6a1ad6ea4b3e3d92e77cc4ccdd7b6c11c1b7
786	2024-12-02 03:44:53.470813+00	2024-12-02 03:44:53.470813+00	\N	http://holote.vn:8083/image-storage/IMG1733111091736065382.jpeg	jpeg	0.03	768	1024	d32ca318f2f4d0302ec1b582a5d1c57925c3ae53684d807d50c354f214ddfc0d
787	2024-12-02 03:45:25.214633+00	2024-12-02 03:45:25.214633+00	\N	http://holote.vn:8083/image-storage/IMG1733111123477013901.jpeg	jpeg	0.50	1024	768	11674ba844aff9c70c5c15840733e432e509bf35da4e07f66855f8f1904d8b54
788	2024-12-02 03:48:19.762722+00	2024-12-02 03:48:19.762722+00	\N	http://holote.vn:8083/image-storage/IMG1733111298025571015.jpeg	jpeg	0.47	1024	768	a0b1c50f16440f3a1f4bbe2c0cd710cc4c77b79f3f629013eed7d885a75a430e
789	2024-12-02 03:57:12.697405+00	2024-12-02 03:57:12.697405+00	\N	http://holote.vn:8083/image-storage/IMG1733111830960960850.jpeg	jpeg	0.03	768	1024	a3f0aa0e0bf4d0454c2dc4d355c1239637afd40eb336df391b69d9b075514575
790	2024-12-02 03:57:29.653598+00	2024-12-02 03:57:29.653598+00	\N	http://holote.vn:8083/image-storage/IMG1733111847917612133.jpeg	jpeg	0.03	768	1024	251d7682de960ff24f4f944832951bc07ff63c1172d47f6cfae449d4a066c9b9
791	2024-12-02 04:01:26.093706+00	2024-12-02 04:01:26.093706+00	\N	http://holote.vn:8083/image-storage/IMG1733112084356637022.jpeg	jpeg	0.04	473	1024	56efdded3cfc01943acd0d7e7692b9c8ad8960b04cebec80f794b8cbf28eef86
792	2024-12-02 04:02:02.404338+00	2024-12-02 04:02:02.404338+00	\N	http://holote.vn:8083/image-storage/IMG1733112120666371081.jpeg	jpeg	0.26	768	1024	f3aaa4b98c78f00a519b3b57708ff540e1e345dd2a83e4b619abc9b80d41b76f
793	2024-12-02 04:02:40.914866+00	2024-12-02 04:02:40.914866+00	\N	http://holote.vn:8083/image-storage/IMG1733112159177539062.jpeg	jpeg	0.24	768	1024	a62edd713e8d6a52bdae4dfc3f253da182c893dfa63f9d19e37df20ca7474ed1
794	2024-12-02 04:03:58.317615+00	2024-12-02 04:03:58.317615+00	\N	http://holote.vn:8083/image-storage/IMG1733112236579611775.jpeg	jpeg	0.27	1024	768	d32625c109196c72e4308c73621f1b5c0fd2388529a0c121f83bfc7f9df349d8
795	2024-12-02 04:03:58.317232+00	2024-12-02 04:03:58.317232+00	\N	http://holote.vn:8083/image-storage/IMG1733112236579611728.jpeg	jpeg	0.25	1024	768	35ed8e58a42b51224cfb3a7143903cf36f50896b0dbf2ef399bc93b74496eff5
796	2024-12-02 04:05:20.443878+00	2024-12-02 04:05:20.443878+00	\N	http://holote.vn:8083/image-storage/IMG1733112318705416769.jpeg	jpeg	0.29	1024	768	0b579abb9e8bd58aff9d68b92b37add732e7e4a153094cd415989bdafaa2bc5f
797	2024-12-02 04:05:20.443961+00	2024-12-02 04:05:20.443961+00	\N	http://holote.vn:8083/image-storage/IMG1733112318705416954.jpeg	jpeg	0.28	1024	768	9b454cb0f84c610538de82be914cb5db402324fa2bc9db5ceeeba0c3da7f2b39
798	2024-12-02 04:11:57.198666+00	2024-12-02 04:11:57.198666+00	\N	http://holote.vn:8083/image-storage/IMG1733112715456879670.jpeg	jpeg	0.43	1024	768	6b3d2d2b325aaff34299f9b2eddf2e30018220025a37c024a7780c1b2ae89380
799	2024-12-02 04:14:42.5455+00	2024-12-02 04:14:42.5455+00	\N	http://holote.vn:8083/image-storage/IMG1733112880804798608.jpeg	jpeg	0.43	1024	768	2405ad51aa3bac0b10e028b5a1f9374f73f1e61923b54afff16584aa4a75d40c
\.


--
-- Data for Name: migrations; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.migrations (id) FROM stdin;
20220523172948
20220523172949
20220523172950
20220523172952
20220523172954
20220523172953
20220523172951
10220523172948
20220523172955
20220523172956
20220523172957
20220523172958
20220523172959
20220523172960
20220523172961
20220523172962
10220523172949
\.


--
-- Data for Name: object_images; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.object_images (id, created_at, updated_at, deleted_at, object_id, object, image_url, purpose, parent_id, uploader_id, uploader_role) FROM stdin;
13	2024-11-07 09:13:00.006218+00	2024-11-07 09:13:00.006218+00	\N	15	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
5	2024-10-21 09:11:43.496553+00	2024-10-21 09:11:43.496553+00	\N	4	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
49	2024-11-15 07:08:32.694633+00	2024-11-15 07:08:32.694633+00	\N	35	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
18	2024-11-07 09:13:06.927739+00	2024-11-07 09:13:06.927739+00	\N	17	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
57	2024-11-15 07:45:20.067437+00	2024-11-15 07:45:20.067437+00	\N	41	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
15	2024-11-07 09:13:06.185709+00	2024-11-07 09:13:06.185709+00	\N	16	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
61	2024-11-15 08:22:19.541685+00	2024-11-15 08:22:19.541685+00	\N	43	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
58	2024-11-15 07:45:20.069528+00	2024-11-15 07:45:20.069528+00	\N	41	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
54	2024-11-15 07:12:25.2892+00	2024-11-15 07:12:25.2892+00	\N	37	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
14	2024-11-07 09:13:00.008519+00	2024-11-07 09:13:00.008519+00	\N	15	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
56	2024-11-15 07:14:18.404398+00	2024-11-15 07:14:18.404398+00	\N	39	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
20	2024-11-07 09:13:07.683916+00	2024-11-07 09:13:07.683916+00	\N	18	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
51	2024-11-15 07:09:04.796292+00	2024-11-15 07:09:04.796292+00	\N	36	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
10	2024-11-03 20:22:04.816639+00	2024-11-03 20:22:04.816639+00	\N	10	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
37	2024-11-08 04:33:04.13987+00	2024-11-08 04:33:04.13987+00	\N	27	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
36	2024-11-07 09:26:43.176905+00	2024-11-07 09:26:43.176905+00	\N	26	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
60	2024-11-15 08:04:49.16647+00	2024-11-15 08:04:49.16647+00	\N	42	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
59	2024-11-15 08:04:49.164269+00	2024-11-15 08:04:49.164269+00	\N	42	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
9	2024-11-03 20:22:04.805058+00	2024-11-03 20:22:04.805058+00	\N	10	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
52	2024-11-15 07:09:04.818789+00	2024-11-15 07:09:04.818789+00	\N	36	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
50	2024-11-15 07:08:32.697411+00	2024-11-15 07:08:32.697411+00	\N	35	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
19	2024-11-07 09:13:07.681379+00	2024-11-07 09:13:07.681379+00	\N	18	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
29	2024-11-07 09:13:10.966404+00	2024-11-07 09:13:10.966404+00	\N	23	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
11	2024-11-07 09:12:39.136383+00	2024-11-07 09:12:39.136383+00	\N	14	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
21	2024-11-07 09:13:08.34611+00	2024-11-07 09:13:08.34611+00	\N	19	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
2	2024-10-17 08:41:36.10369+00	2024-10-17 08:41:36.10369+00	\N	1	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
3	2024-10-21 09:11:21.806618+00	2024-10-21 09:11:21.806618+00	\N	3	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
1	2024-10-17 08:41:36.022808+00	2024-10-17 08:41:36.022808+00	\N	1	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
28	2024-11-07 09:13:10.356192+00	2024-11-07 09:13:10.356192+00	\N	22	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
27	2024-11-07 09:13:10.353563+00	2024-11-07 09:13:10.353563+00	\N	22	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
70	2024-11-15 08:46:35.652838+00	2024-11-15 08:46:35.652838+00	\N	47	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
12	2024-11-07 09:12:39.144315+00	2024-11-07 09:12:39.144315+00	\N	14	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
22	2024-11-07 09:13:08.34869+00	2024-11-07 09:13:08.34869+00	\N	19	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
43	2024-11-14 07:37:17.525714+00	2024-11-14 07:37:17.525714+00	\N	31	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
66	2024-11-15 08:32:52.939787+00	2024-11-15 08:32:52.939787+00	\N	45	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
63	2024-11-15 08:28:07.48488+00	2024-11-15 08:28:07.48488+00	\N	44	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
62	2024-11-15 08:22:19.544366+00	2024-11-15 08:22:19.544366+00	\N	43	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
35	2024-11-07 09:26:43.174189+00	2024-11-07 09:26:43.174189+00	\N	26	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
34	2024-11-07 09:13:12.734414+00	2024-11-07 09:13:12.734414+00	\N	25	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
8	2024-10-21 09:33:09.30766+00	2024-10-21 09:33:09.30766+00	\N	5	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
68	2024-11-15 08:45:20.026666+00	2024-11-15 08:45:20.026666+00	\N	46	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
45	2024-11-15 04:19:56.407182+00	2024-11-15 04:19:56.407182+00	\N	32	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
38	2024-11-08 04:33:04.142906+00	2024-11-08 04:33:04.142906+00	\N	27	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
64	2024-11-15 08:28:07.487662+00	2024-11-15 08:28:07.487662+00	\N	44	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
67	2024-11-15 08:45:20.024134+00	2024-11-15 08:45:20.024134+00	\N	46	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
42	2024-11-11 15:23:42.683716+00	2024-11-11 15:23:42.683716+00	\N	30	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
41	2024-11-11 15:23:42.681526+00	2024-11-11 15:23:42.681526+00	\N	30	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
40	2024-11-11 15:22:00.021296+00	2024-11-11 15:22:00.021296+00	\N	29	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
44	2024-11-14 07:37:17.531582+00	2024-11-14 07:37:17.531582+00	\N	31	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
69	2024-11-15 08:46:35.650378+00	2024-11-15 08:46:35.650378+00	\N	47	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
39	2024-11-11 15:22:00.004402+00	2024-11-11 15:22:00.004402+00	\N	29	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
65	2024-11-15 08:32:52.937368+00	2024-11-15 08:32:52.937368+00	\N	45	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
576	2024-11-21 08:15:31.331933+00	2024-11-21 08:15:31.331933+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
577	2024-11-21 08:15:31.424204+00	2024-11-21 08:15:31.424204+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
609	2024-11-21 08:19:44.676087+00	2024-11-21 08:19:44.676087+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
610	2024-11-21 08:19:44.781425+00	2024-11-21 08:19:44.781425+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
642	2024-11-21 08:20:27.931979+00	2024-11-21 08:20:27.931979+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
643	2024-11-21 08:20:28.035956+00	2024-11-21 08:20:28.035956+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
675	2024-11-21 08:21:26.984506+00	2024-11-21 08:21:26.984506+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
676	2024-11-21 08:21:27.090912+00	2024-11-21 08:21:27.090912+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
708	2024-11-21 08:24:19.220872+00	2024-11-21 08:24:19.220872+00	\N	337	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
709	2024-11-21 08:24:19.31889+00	2024-11-21 08:24:19.31889+00	\N	337	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
710	2024-11-21 08:24:26.12147+00	2024-11-21 08:24:26.12147+00	\N	337	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
6	2024-10-21 09:11:43.599563+00	2024-10-21 09:11:43.599563+00	\N	4	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
16	2024-11-07 09:13:06.188165+00	2024-11-07 09:13:06.188165+00	\N	16	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
24	2024-11-07 09:13:09.009914+00	2024-11-07 09:13:09.009914+00	\N	20	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
55	2024-11-15 07:14:18.401721+00	2024-11-15 07:14:18.401721+00	\N	39	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
32	2024-11-07 09:13:11.635946+00	2024-11-07 09:13:11.635946+00	\N	24	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
33	2024-11-07 09:13:12.73152+00	2024-11-07 09:13:12.73152+00	\N	25	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
25	2024-11-07 09:13:09.732797+00	2024-11-07 09:13:09.732797+00	\N	21	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
47	2024-11-15 04:23:51.010114+00	2024-11-15 04:23:51.010114+00	\N	33	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
17	2024-11-07 09:13:06.922978+00	2024-11-07 09:13:06.922978+00	\N	17	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
7	2024-10-21 09:33:09.225693+00	2024-10-21 09:33:09.225693+00	\N	5	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
48	2024-11-15 04:23:51.01272+00	2024-11-15 04:23:51.01272+00	\N	33	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
23	2024-11-07 09:13:09.007634+00	2024-11-07 09:13:09.007634+00	\N	20	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
4	2024-10-21 09:11:21.91357+00	2024-10-21 09:11:21.91357+00	\N	3	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
31	2024-11-07 09:13:11.633572+00	2024-11-07 09:13:11.633572+00	\N	24	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
30	2024-11-07 09:13:10.968691+00	2024-11-07 09:13:10.968691+00	\N	23	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
26	2024-11-07 09:13:09.735278+00	2024-11-07 09:13:09.735278+00	\N	21	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
53	2024-11-15 07:12:25.287107+00	2024-11-15 07:12:25.287107+00	\N	37	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
46	2024-11-15 04:19:56.476246+00	2024-11-15 04:19:56.476246+00	\N	32	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
71	2024-11-19 09:40:38.04834+00	2024-11-19 09:40:38.04834+00	\N	247	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
72	2024-11-19 09:40:38.062803+00	2024-11-19 09:40:38.062803+00	\N	247	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
73	2024-11-20 08:09:05.689154+00	2024-11-20 08:09:05.689154+00	\N	254	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
74	2024-11-20 08:09:05.696448+00	2024-11-20 08:09:05.696448+00	\N	254	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
75	2024-11-20 08:30:55.55701+00	2024-11-20 08:30:55.55701+00	\N	256	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
76	2024-11-20 08:30:55.561885+00	2024-11-20 08:30:55.561885+00	\N	256	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
77	2024-11-20 10:10:40.429972+00	2024-11-20 10:10:40.429972+00	\N	262	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
78	2024-11-20 10:10:40.439933+00	2024-11-20 10:10:40.439933+00	\N	262	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
79	2024-11-20 10:11:59.262715+00	2024-11-20 10:11:59.262715+00	\N	263	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
80	2024-11-20 10:11:59.355579+00	2024-11-20 10:11:59.355579+00	\N	263	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
81	2024-11-21 06:36:31.631164+00	2024-11-21 06:36:31.631164+00	\N	265	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
82	2024-11-21 06:36:31.648122+00	2024-11-21 06:36:31.648122+00	\N	265	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
114	2024-11-21 06:40:38.93248+00	2024-11-21 06:40:38.93248+00	\N	298	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
115	2024-11-21 06:40:38.93582+00	2024-11-21 06:40:38.93582+00	\N	298	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
147	2024-11-21 07:48:42.717298+00	2024-11-21 07:48:42.717298+00	\N	106	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
148	2024-11-21 07:48:42.722892+00	2024-11-21 07:48:42.722892+00	\N	106	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
180	2024-11-21 07:50:17.792419+00	2024-11-21 07:50:17.792419+00	\N	106	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
181	2024-11-21 07:50:17.796343+00	2024-11-21 07:50:17.796343+00	\N	106	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
213	2024-11-21 07:55:22.182116+00	2024-11-21 07:55:22.182116+00	\N	139	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
214	2024-11-21 07:55:22.267421+00	2024-11-21 07:55:22.267421+00	\N	139	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
246	2024-11-21 07:57:38.824357+00	2024-11-21 07:57:38.824357+00	\N	139	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
247	2024-11-21 07:57:38.907743+00	2024-11-21 07:57:38.907743+00	\N	139	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
279	2024-11-21 07:58:40.103353+00	2024-11-21 07:58:40.103353+00	\N	172	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
280	2024-11-21 07:58:40.190777+00	2024-11-21 07:58:40.190777+00	\N	172	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
312	2024-11-21 07:58:58.99225+00	2024-11-21 07:58:58.99225+00	\N	172	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
313	2024-11-21 07:58:59.082224+00	2024-11-21 07:58:59.082224+00	\N	172	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
345	2024-11-21 08:00:22.799597+00	2024-11-21 08:00:22.799597+00	\N	205	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
346	2024-11-21 08:00:22.910159+00	2024-11-21 08:00:22.910159+00	\N	205	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
378	2024-11-21 08:03:48.211807+00	2024-11-21 08:03:48.211807+00	\N	238	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
379	2024-11-21 08:03:48.304333+00	2024-11-21 08:03:48.304333+00	\N	238	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
411	2024-11-21 08:03:55.234452+00	2024-11-21 08:03:55.234452+00	\N	205	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
412	2024-11-21 08:03:55.333819+00	2024-11-21 08:03:55.333819+00	\N	205	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
444	2024-11-21 08:07:42.203831+00	2024-11-21 08:07:42.203831+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
445	2024-11-21 08:07:42.317182+00	2024-11-21 08:07:42.317182+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
446	2024-11-21 08:07:52.245838+00	2024-11-21 08:07:52.245838+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
447	2024-11-21 08:07:52.333142+00	2024-11-21 08:07:52.333142+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
477	2024-11-21 08:10:49.698193+00	2024-11-21 08:10:49.698193+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
478	2024-11-21 08:10:49.794188+00	2024-11-21 08:10:49.794188+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
510	2024-11-21 08:13:32.799404+00	2024-11-21 08:13:32.799404+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
511	2024-11-21 08:13:32.897042+00	2024-11-21 08:13:32.897042+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
543	2024-11-21 08:14:15.730325+00	2024-11-21 08:14:15.730325+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
544	2024-11-21 08:14:15.82418+00	2024-11-21 08:14:15.82418+00	\N	304	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
711	2024-11-21 08:24:26.207991+00	2024-11-21 08:24:26.207991+00	\N	337	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
741	2024-11-21 08:26:44.454781+00	2024-11-21 08:26:44.454781+00	\N	370	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
742	2024-11-21 08:26:44.544511+00	2024-11-21 08:26:44.544511+00	\N	370	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
743	2024-11-21 08:26:47.994136+00	2024-11-21 08:26:47.994136+00	\N	370	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
744	2024-11-21 08:26:48.083261+00	2024-11-21 08:26:48.083261+00	\N	370	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
774	2024-11-21 08:41:46.756667+00	2024-11-21 08:41:46.756667+00	\N	403	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
775	2024-11-21 08:41:46.847806+00	2024-11-21 08:41:46.847806+00	\N	403	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
807	2024-11-21 08:44:12.922807+00	2024-11-21 08:44:12.922807+00	\N	403	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
808	2024-11-21 08:44:13.014187+00	2024-11-21 08:44:13.014187+00	\N	403	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
840	2024-11-21 09:01:31.399919+00	2024-11-21 09:01:31.399919+00	\N	403	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
841	2024-11-21 09:01:31.52524+00	2024-11-21 09:01:31.52524+00	\N	403	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
842	2024-11-21 09:01:36.137057+00	2024-11-21 09:01:36.137057+00	\N	403	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
843	2024-11-21 09:01:36.262281+00	2024-11-21 09:01:36.262281+00	\N	403	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
844	2024-11-21 09:16:22.529153+00	2024-11-21 09:16:22.529153+00	\N	404	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
845	2024-11-21 09:16:22.654683+00	2024-11-21 09:16:22.654683+00	\N	404	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
846	2024-11-21 09:17:00.26156+00	2024-11-21 09:17:00.26156+00	\N	405	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
847	2024-11-21 09:17:00.388217+00	2024-11-21 09:17:00.388217+00	\N	405	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
848	2024-11-21 09:24:15.282657+00	2024-11-21 09:24:15.282657+00	\N	405	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
849	2024-11-21 09:24:15.408907+00	2024-11-21 09:24:15.408907+00	\N	405	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
850	2024-11-21 10:17:35.35765+00	2024-11-21 10:17:35.35765+00	\N	406	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
851	2024-11-21 10:17:35.481782+00	2024-11-21 10:17:35.481782+00	\N	406	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
852	2024-11-21 10:22:48.972259+00	2024-11-21 10:22:48.972259+00	\N	406	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
853	2024-11-21 10:22:49.080911+00	2024-11-21 10:22:49.080911+00	\N	406	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
854	2024-11-21 10:23:59.653202+00	2024-11-21 10:23:59.653202+00	\N	406	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
855	2024-11-21 10:23:59.77859+00	2024-11-21 10:23:59.77859+00	\N	406	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
856	2024-11-21 10:25:22.942786+00	2024-11-21 10:25:22.942786+00	\N	407	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
857	2024-11-21 10:25:23.067786+00	2024-11-21 10:25:23.067786+00	\N	407	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
858	2024-11-21 10:25:47.84228+00	2024-11-21 10:25:47.84228+00	\N	407	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
859	2024-11-21 10:25:47.966655+00	2024-11-21 10:25:47.966655+00	\N	407	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
860	2024-11-22 01:43:48.370684+00	2024-11-22 01:43:48.370684+00	\N	401	vehicle	http://holote.vn:8083/image-storage/IMG1732239826505217359.jpeg	create_vehicle_image	\N	\N	\N
861	2024-11-22 01:43:48.497898+00	2024-11-22 01:43:48.497898+00	\N	401	vehicle	http://holote.vn:8083/image-storage/IMG1732239826502786340.jpeg	create_vehicle_image	\N	\N	\N
862	2024-11-22 01:43:48.625029+00	2024-11-22 01:43:48.625029+00	\N	401	vehicle	http://holote.vn:8083/image-storage/IMG1732239826507303263.jpeg	create_vehicle_image	\N	\N	\N
863	2024-11-22 03:48:24.616321+00	2024-11-22 03:48:24.616321+00	\N	404	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
864	2024-11-22 03:48:24.73426+00	2024-11-22 03:48:24.73426+00	\N	404	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
865	2024-11-22 03:48:59.225731+00	2024-11-22 03:48:59.225731+00	\N	409	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
866	2024-11-22 03:48:59.333714+00	2024-11-22 03:48:59.333714+00	\N	409	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
867	2024-11-22 03:49:20.640058+00	2024-11-22 03:49:20.640058+00	\N	409	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
868	2024-11-22 03:49:20.74617+00	2024-11-22 03:49:20.74617+00	\N	409	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
869	2024-11-22 03:50:37.151855+00	2024-11-22 03:50:37.151855+00	\N	410	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
870	2024-11-22 03:50:37.282254+00	2024-11-22 03:50:37.282254+00	\N	410	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
871	2024-11-22 03:51:05.877023+00	2024-11-22 03:51:05.877023+00	\N	410	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
872	2024-11-22 03:51:06.04117+00	2024-11-22 03:51:06.04117+00	\N	410	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
873	2024-11-22 03:51:23.4139+00	2024-11-22 03:51:23.4139+00	\N	411	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
874	2024-11-22 03:51:23.54506+00	2024-11-22 03:51:23.54506+00	\N	411	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
875	2024-11-22 03:51:29.020102+00	2024-11-22 03:51:29.020102+00	\N	411	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
876	2024-11-22 03:51:29.147422+00	2024-11-22 03:51:29.147422+00	\N	411	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
877	2024-11-22 03:52:32.668676+00	2024-11-22 03:52:32.668676+00	\N	412	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
878	2024-11-22 03:52:32.799858+00	2024-11-22 03:52:32.799858+00	\N	412	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
879	2024-11-22 03:52:38.234794+00	2024-11-22 03:52:38.234794+00	\N	412	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
880	2024-11-22 03:52:38.367741+00	2024-11-22 03:52:38.367741+00	\N	412	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
881	2024-11-22 03:54:27.210771+00	2024-11-22 03:54:27.210771+00	\N	413	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
882	2024-11-22 03:54:27.337988+00	2024-11-22 03:54:27.337988+00	\N	413	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
883	2024-11-22 03:54:33.706441+00	2024-11-22 03:54:33.706441+00	\N	413	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
884	2024-11-22 03:54:33.835015+00	2024-11-22 03:54:33.835015+00	\N	413	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
885	2024-11-22 03:54:54.038661+00	2024-11-22 03:54:54.038661+00	\N	414	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
886	2024-11-22 03:54:54.169503+00	2024-11-22 03:54:54.169503+00	\N	414	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
887	2024-11-22 03:54:57.189842+00	2024-11-22 03:54:57.189842+00	\N	414	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
888	2024-11-22 03:54:57.31941+00	2024-11-22 03:54:57.31941+00	\N	414	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
889	2024-11-22 03:55:21.647844+00	2024-11-22 03:55:21.647844+00	\N	415	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
890	2024-11-22 03:55:21.773767+00	2024-11-22 03:55:21.773767+00	\N	415	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
891	2024-11-22 03:55:25.304998+00	2024-11-22 03:55:25.304998+00	\N	415	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
892	2024-11-22 03:55:25.432139+00	2024-11-22 03:55:25.432139+00	\N	415	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
893	2024-11-22 03:55:31.838673+00	2024-11-22 03:55:31.838673+00	\N	416	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
894	2024-11-22 03:55:31.965565+00	2024-11-22 03:55:31.965565+00	\N	416	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
895	2024-11-22 03:55:40.183664+00	2024-11-22 03:55:40.183664+00	\N	416	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
896	2024-11-22 03:55:40.309916+00	2024-11-22 03:55:40.309916+00	\N	416	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
897	2024-11-22 04:03:14.228941+00	2024-11-22 04:03:14.228941+00	\N	417	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
898	2024-11-22 04:03:14.336742+00	2024-11-22 04:03:14.336742+00	\N	417	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
899	2024-11-22 04:06:09.200106+00	2024-11-22 04:06:09.200106+00	\N	417	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
900	2024-11-22 04:06:12.266769+00	2024-11-22 04:06:12.266769+00	\N	417	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
901	2024-11-22 04:07:38.762933+00	2024-11-22 04:07:38.762933+00	\N	417	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
902	2024-11-22 04:07:38.896573+00	2024-11-22 04:07:38.896573+00	\N	417	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
903	2024-11-22 04:09:55.624019+00	2024-11-22 04:09:55.624019+00	\N	417	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
904	2024-11-22 04:09:55.737752+00	2024-11-22 04:09:55.737752+00	\N	417	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
905	2024-11-22 04:10:11.848816+00	2024-11-22 04:10:11.848816+00	\N	417	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
906	2024-11-22 04:10:11.961784+00	2024-11-22 04:10:11.961784+00	\N	417	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
907	2024-11-22 04:10:40.196599+00	2024-11-22 04:10:40.196599+00	\N	418	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
908	2024-11-22 04:10:40.299619+00	2024-11-22 04:10:40.299619+00	\N	418	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
909	2024-11-22 04:10:43.791861+00	2024-11-22 04:10:43.791861+00	\N	418	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
910	2024-11-22 04:10:43.902811+00	2024-11-22 04:10:43.902811+00	\N	418	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
911	2024-11-22 04:10:47.370076+00	2024-11-22 04:10:47.370076+00	\N	419	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
912	2024-11-22 04:10:47.47276+00	2024-11-22 04:10:47.47276+00	\N	419	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
913	2024-11-22 04:10:50.173789+00	2024-11-22 04:10:50.173789+00	\N	419	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
914	2024-11-22 04:10:50.280753+00	2024-11-22 04:10:50.280753+00	\N	419	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
915	2024-11-22 04:11:23.570851+00	2024-11-22 04:11:23.570851+00	\N	420	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
916	2024-11-22 04:11:23.678203+00	2024-11-22 04:11:23.678203+00	\N	420	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
917	2024-11-22 04:11:26.402675+00	2024-11-22 04:11:26.402675+00	\N	420	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
918	2024-11-22 04:11:26.510876+00	2024-11-22 04:11:26.510876+00	\N	420	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
919	2024-11-22 04:49:29.67536+00	2024-11-22 04:49:29.67536+00	\N	402	vehicle	http://holote.vn:8083/image-storage/IMG1732250968362726398.jpeg	create_vehicle_image	\N	\N	\N
920	2024-11-22 04:53:51.843829+00	2024-11-22 04:53:51.843829+00	\N	403	vehicle	http://holote.vn:8083/image-storage/IMG1732251230404365880.jpeg	create_vehicle_image	\N	\N	\N
921	2024-11-22 04:54:17.714595+00	2024-11-22 04:54:17.714595+00	\N	404	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
922	2024-11-22 04:54:17.825283+00	2024-11-22 04:54:17.825283+00	\N	404	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
923	2024-11-22 07:01:37.8092+00	2024-11-22 07:01:37.8092+00	\N	405	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
924	2024-11-22 07:01:37.935584+00	2024-11-22 07:01:37.935584+00	\N	405	vehicle	http://placeimg.com/640/480	create_vehicle_image	\N	\N	\N
925	2024-11-22 08:39:52.827492+00	2024-11-22 08:39:52.827492+00	\N	421	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
926	2024-11-22 08:39:52.953392+00	2024-11-22 08:39:52.953392+00	\N	421	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
927	2024-11-22 08:40:38.187756+00	2024-11-22 08:40:38.187756+00	\N	421	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
928	2024-11-22 08:40:38.312424+00	2024-11-22 08:40:38.312424+00	\N	421	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
929	2024-11-22 08:42:06.049899+00	2024-11-22 08:42:06.049899+00	\N	422	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
930	2024-11-22 08:42:06.174636+00	2024-11-22 08:42:06.174636+00	\N	422	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
931	2024-11-22 08:42:30.863903+00	2024-11-22 08:42:30.863903+00	\N	422	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
932	2024-11-22 08:42:30.988643+00	2024-11-22 08:42:30.988643+00	\N	422	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
933	2024-11-22 08:52:20.138425+00	2024-11-22 08:52:20.138425+00	\N	423	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
934	2024-11-22 08:52:20.263709+00	2024-11-22 08:52:20.263709+00	\N	423	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
935	2024-11-22 08:52:34.612259+00	2024-11-22 08:52:34.612259+00	\N	423	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
936	2024-11-22 08:52:34.737652+00	2024-11-22 08:52:34.737652+00	\N	423	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
937	2024-11-22 08:59:15.743485+00	2024-11-22 08:59:15.743485+00	\N	424	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
938	2024-11-22 08:59:15.868453+00	2024-11-22 08:59:15.868453+00	\N	424	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
939	2024-11-22 08:59:36.374841+00	2024-11-22 08:59:36.374841+00	\N	424	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
940	2024-11-22 08:59:36.499079+00	2024-11-22 08:59:36.499079+00	\N	424	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
941	2024-11-22 09:00:27.316275+00	2024-11-22 09:00:27.316275+00	\N	425	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
942	2024-11-22 09:00:27.442208+00	2024-11-22 09:00:27.442208+00	\N	425	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
943	2024-11-22 09:00:37.253792+00	2024-11-22 09:00:37.253792+00	\N	425	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
944	2024-11-22 09:00:37.378551+00	2024-11-22 09:00:37.378551+00	\N	425	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
945	2024-11-22 09:04:20.616443+00	2024-11-22 09:04:20.616443+00	\N	426	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
946	2024-11-22 09:04:20.922719+00	2024-11-22 09:04:20.922719+00	\N	426	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
947	2024-11-22 09:04:34.822412+00	2024-11-22 09:04:34.822412+00	\N	426	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
948	2024-11-22 09:04:34.947321+00	2024-11-22 09:04:34.947321+00	\N	426	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
949	2024-11-22 09:24:59.225173+00	2024-11-22 09:24:59.225173+00	\N	427	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
950	2024-11-22 09:24:59.349187+00	2024-11-22 09:24:59.349187+00	\N	427	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
951	2024-11-22 09:25:20.696314+00	2024-11-22 09:25:20.696314+00	\N	427	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
952	2024-11-22 09:25:20.821076+00	2024-11-22 09:25:20.821076+00	\N	427	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
953	2024-11-22 09:26:14.160484+00	2024-11-22 09:26:14.160484+00	\N	428	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
954	2024-11-22 09:26:14.284984+00	2024-11-22 09:26:14.284984+00	\N	428	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
955	2024-11-22 09:26:37.237834+00	2024-11-22 09:26:37.237834+00	\N	428	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
956	2024-11-22 09:26:37.362706+00	2024-11-22 09:26:37.362706+00	\N	428	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
957	2024-11-22 09:42:14.757328+00	2024-11-22 09:42:14.757328+00	\N	429	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
958	2024-11-22 09:42:14.881223+00	2024-11-22 09:42:14.881223+00	\N	429	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
959	2024-11-22 09:42:44.96562+00	2024-11-22 09:42:44.96562+00	\N	429	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
960	2024-11-22 09:42:45.090634+00	2024-11-22 09:42:45.090634+00	\N	429	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
961	2024-11-22 09:43:34.835537+00	2024-11-22 09:43:34.835537+00	\N	430	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
962	2024-11-22 09:43:34.959215+00	2024-11-22 09:43:34.959215+00	\N	430	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
963	2024-11-22 09:43:47.059645+00	2024-11-22 09:43:47.059645+00	\N	430	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
964	2024-11-22 09:43:47.183452+00	2024-11-22 09:43:47.183452+00	\N	430	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
965	2024-11-22 09:45:02.40692+00	2024-11-22 09:45:02.40692+00	\N	432	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
966	2024-11-22 09:45:02.531322+00	2024-11-22 09:45:02.531322+00	\N	432	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
967	2024-11-22 09:45:09.318598+00	2024-11-22 09:45:09.318598+00	\N	432	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
968	2024-11-22 09:45:09.443681+00	2024-11-22 09:45:09.443681+00	\N	432	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
969	2024-11-23 03:57:20.453829+00	2024-11-23 03:57:20.453829+00	\N	425	vehicle	http://holote.vn:8083/image-storage/IMG1732334238845550317.jpeg	create_vehicle_image	\N	\N	\N
970	2024-11-23 04:00:30.886835+00	2024-11-23 04:00:30.886835+00	\N	426	vehicle	http://holote.vn:8083/image-storage/IMG1732334429292466783.jpeg	create_vehicle_image	\N	\N	\N
971	2024-11-25 01:52:02.333442+00	2024-11-25 01:52:02.333442+00	\N	677	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
972	2024-11-25 01:52:02.460348+00	2024-11-25 01:52:02.460348+00	\N	677	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
973	2024-11-25 02:54:57.678947+00	2024-11-25 02:54:57.678947+00	\N	433	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
974	2024-11-25 02:54:57.804707+00	2024-11-25 02:54:57.804707+00	\N	433	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
975	2024-11-25 02:55:31.018394+00	2024-11-25 02:55:31.018394+00	\N	433	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
976	2024-11-25 02:55:31.143756+00	2024-11-25 02:55:31.143756+00	\N	433	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
977	2024-11-25 02:56:15.53311+00	2024-11-25 02:56:15.53311+00	\N	434	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
978	2024-11-25 02:56:15.658575+00	2024-11-25 02:56:15.658575+00	\N	434	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
979	2024-11-25 02:56:29.967663+00	2024-11-25 02:56:29.967663+00	\N	434	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
980	2024-11-25 02:56:30.093263+00	2024-11-25 02:56:30.093263+00	\N	434	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
981	2024-11-25 02:56:50.018709+00	2024-11-25 02:56:50.018709+00	\N	435	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
982	2024-11-25 02:56:50.143999+00	2024-11-25 02:56:50.143999+00	\N	435	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
983	2024-11-25 03:06:23.541933+00	2024-11-25 03:06:23.541933+00	\N	436	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
984	2024-11-25 03:06:23.667087+00	2024-11-25 03:06:23.667087+00	\N	436	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
985	2024-11-25 03:06:48.357426+00	2024-11-25 03:06:48.357426+00	\N	436	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
986	2024-11-25 03:06:48.483255+00	2024-11-25 03:06:48.483255+00	\N	436	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
987	2024-11-25 03:08:41.606793+00	2024-11-25 03:08:41.606793+00	\N	437	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
988	2024-11-25 03:08:41.732412+00	2024-11-25 03:08:41.732412+00	\N	437	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
989	2024-11-25 03:13:52.559706+00	2024-11-25 03:13:52.559706+00	\N	438	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
990	2024-11-25 03:13:52.685669+00	2024-11-25 03:13:52.685669+00	\N	438	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
991	2024-11-25 03:15:31.080161+00	2024-11-25 03:15:31.080161+00	\N	439	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
992	2024-11-25 03:15:31.206366+00	2024-11-25 03:15:31.206366+00	\N	439	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
993	2024-11-25 03:15:50.405554+00	2024-11-25 03:15:50.405554+00	\N	439	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
994	2024-11-25 03:15:50.532676+00	2024-11-25 03:15:50.532676+00	\N	439	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
995	2024-11-25 03:23:37.10805+00	2024-11-25 03:23:37.10805+00	\N	440	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
996	2024-11-25 03:23:37.234095+00	2024-11-25 03:23:37.234095+00	\N	440	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
997	2024-11-25 03:37:02.274262+00	2024-11-25 03:37:02.274262+00	\N	441	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
998	2024-11-25 03:37:02.400392+00	2024-11-25 03:37:02.400392+00	\N	441	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
999	2024-11-25 03:37:18.682258+00	2024-11-25 03:37:18.682258+00	\N	441	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1000	2024-11-25 03:37:18.808029+00	2024-11-25 03:37:18.808029+00	\N	441	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1001	2024-11-25 03:38:14.924989+00	2024-11-25 03:38:14.924989+00	\N	442	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1002	2024-11-25 03:38:15.051383+00	2024-11-25 03:38:15.051383+00	\N	442	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1003	2024-11-25 03:39:47.042713+00	2024-11-25 03:39:47.042713+00	\N	427	vehicle	http://holote.vn:8083/image-storage/IMG1732505985871694929.jpeg	create_vehicle_image	\N	\N	\N
1004	2024-11-25 04:00:30.323922+00	2024-11-25 04:00:30.323922+00	\N	677	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1005	2024-11-25 04:00:30.323922+00	2024-11-25 04:00:30.323922+00	\N	677	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1006	2024-11-25 04:20:29.264941+00	2024-11-25 04:20:29.264941+00	\N	428	vehicle	http://holote.vn:8083/image-storage/IMG1732508428006682644.jpeg	create_vehicle_image	\N	\N	\N
1007	2024-11-25 04:22:48.55025+00	2024-11-25 04:22:48.55025+00	\N	429	vehicle	http://holote.vn:8083/image-storage/IMG1732508567373622302.jpeg	create_vehicle_image	\N	\N	\N
1008	2024-11-25 04:32:04.100976+00	2024-11-25 04:32:04.100976+00	\N	443	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1009	2024-11-25 04:32:04.226918+00	2024-11-25 04:32:04.226918+00	\N	443	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1010	2024-11-25 04:32:33.990832+00	2024-11-25 04:32:33.990832+00	\N	443	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1011	2024-11-25 04:32:34.115863+00	2024-11-25 04:32:34.115863+00	\N	443	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1012	2024-11-25 04:36:24.032455+00	2024-11-25 04:36:24.032455+00	\N	444	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1013	2024-11-25 04:36:24.158511+00	2024-11-25 04:36:24.158511+00	\N	444	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1014	2024-11-25 04:37:21.817692+00	2024-11-25 04:37:21.817692+00	\N	444	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1015	2024-11-25 04:37:21.942893+00	2024-11-25 04:37:21.942893+00	\N	444	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1016	2024-11-25 04:48:23.208545+00	2024-11-25 04:48:23.208545+00	\N	445	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1017	2024-11-25 04:48:23.334511+00	2024-11-25 04:48:23.334511+00	\N	445	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1018	2024-11-25 04:48:41.63617+00	2024-11-25 04:48:41.63617+00	\N	445	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1019	2024-11-25 04:48:41.760938+00	2024-11-25 04:48:41.760938+00	\N	445	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1020	2024-11-25 07:05:58.485119+00	2024-11-25 07:05:58.485119+00	\N	447	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1021	2024-11-25 07:05:58.611262+00	2024-11-25 07:05:58.611262+00	\N	447	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1022	2024-11-25 07:06:23.604608+00	2024-11-25 07:06:23.604608+00	\N	447	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1023	2024-11-25 07:06:23.730476+00	2024-11-25 07:06:23.730476+00	\N	447	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1024	2024-11-25 07:07:19.159167+00	2024-11-25 07:07:19.159167+00	\N	448	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1025	2024-11-25 07:07:19.284177+00	2024-11-25 07:07:19.284177+00	\N	448	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1026	2024-11-25 07:14:54.021412+00	2024-11-25 07:14:54.021412+00	\N	448	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1027	2024-11-25 07:14:54.146384+00	2024-11-25 07:14:54.146384+00	\N	448	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1028	2024-11-25 07:19:27.392231+00	2024-11-25 07:19:27.392231+00	\N	449	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1029	2024-11-25 07:19:27.518863+00	2024-11-25 07:19:27.518863+00	\N	449	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1030	2024-11-25 07:19:59.294858+00	2024-11-25 07:19:59.294858+00	\N	449	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1031	2024-11-25 07:19:59.420463+00	2024-11-25 07:19:59.420463+00	\N	449	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1032	2024-11-25 07:20:40.886174+00	2024-11-25 07:20:40.886174+00	\N	450	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1033	2024-11-25 07:20:41.011771+00	2024-11-25 07:20:41.011771+00	\N	450	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1034	2024-11-25 07:31:10.883991+00	2024-11-25 07:31:10.883991+00	\N	451	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1035	2024-11-25 07:31:11.012854+00	2024-11-25 07:31:11.012854+00	\N	451	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1036	2024-11-25 07:32:45.393419+00	2024-11-25 07:32:45.393419+00	\N	452	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1037	2024-11-25 07:32:45.521383+00	2024-11-25 07:32:45.521383+00	\N	452	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1038	2024-11-25 07:33:36.10546+00	2024-11-25 07:33:36.10546+00	\N	453	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1039	2024-11-25 07:33:36.224837+00	2024-11-25 07:33:36.224837+00	\N	453	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1040	2024-11-25 07:35:05.784207+00	2024-11-25 07:35:05.784207+00	\N	454	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1041	2024-11-25 07:35:05.889871+00	2024-11-25 07:35:05.889871+00	\N	454	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1042	2024-11-25 07:37:26.219705+00	2024-11-25 07:37:26.219705+00	\N	454	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1043	2024-11-25 07:37:26.352506+00	2024-11-25 07:37:26.352506+00	\N	454	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1044	2024-11-25 07:53:30.709046+00	2024-11-25 07:53:30.709046+00	\N	456	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1045	2024-11-25 07:53:30.835308+00	2024-11-25 07:53:30.835308+00	\N	456	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1046	2024-11-25 07:53:46.685483+00	2024-11-25 07:53:46.685483+00	\N	456	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1047	2024-11-25 07:53:46.810977+00	2024-11-25 07:53:46.810977+00	\N	456	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1048	2024-11-25 07:58:54.068497+00	2024-11-25 07:58:54.068497+00	\N	681	order	http://holote.vn:8083/image-storage/IMG1732521532676148007.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1049	2024-11-25 07:58:54.194737+00	2024-11-25 07:58:54.194737+00	\N	681	order	http://holote.vn:8083/image-storage/IMG1732521532678458559.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1050	2024-11-25 08:02:55.62423+00	2024-11-25 08:02:55.62423+00	\N	430	vehicle	http://holote.vn:8083/image-storage/IMG1732521774368820334.jpeg	create_vehicle_image	\N	\N	\N
1051	2024-11-25 08:30:32.929311+00	2024-11-25 08:30:32.929311+00	\N	681	order	http://holote.vn:8083/image-storage/IMG1732523431504339828.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1052	2024-11-25 08:30:33.055361+00	2024-11-25 08:30:33.055361+00	\N	681	order	http://holote.vn:8083/image-storage/IMG1732523431504366587.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1053	2024-11-25 08:39:51.082535+00	2024-11-25 08:39:51.082535+00	\N	689	order	http://holote.vn:8083/image-storage/IMG1732523989678932998.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1054	2024-11-25 08:39:51.208429+00	2024-11-25 08:39:51.208429+00	\N	689	order	http://holote.vn:8083/image-storage/IMG1732523989678960124.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1055	2024-11-25 08:42:37.320021+00	2024-11-25 08:42:37.320021+00	\N	457	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1056	2024-11-25 08:42:37.446381+00	2024-11-25 08:42:37.446381+00	\N	457	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1057	2024-11-25 08:42:43.614158+00	2024-11-25 08:42:43.614158+00	\N	689	order	http://holote.vn:8083/image-storage/IMG1732524162430666315.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1058	2024-11-25 08:42:56.018119+00	2024-11-25 08:42:56.018119+00	\N	457	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1059	2024-11-25 08:42:56.144686+00	2024-11-25 08:42:56.144686+00	\N	457	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1060	2024-11-25 08:43:45.41223+00	2024-11-25 08:43:45.41223+00	\N	458	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1061	2024-11-25 08:43:45.537285+00	2024-11-25 08:43:45.537285+00	\N	458	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1062	2024-11-25 08:43:57.122971+00	2024-11-25 08:43:57.122971+00	\N	458	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1063	2024-11-25 08:43:57.248623+00	2024-11-25 08:43:57.248623+00	\N	458	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1064	2024-11-25 09:07:24.727319+00	2024-11-25 09:07:24.727319+00	\N	459	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1065	2024-11-25 09:07:24.853267+00	2024-11-25 09:07:24.853267+00	\N	459	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1066	2024-11-25 09:07:37.735155+00	2024-11-25 09:07:37.735155+00	\N	459	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1067	2024-11-25 09:07:37.860167+00	2024-11-25 09:07:37.860167+00	\N	459	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1068	2024-11-25 09:08:05.709485+00	2024-11-25 09:08:05.709485+00	\N	460	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1069	2024-11-25 09:08:05.834837+00	2024-11-25 09:08:05.834837+00	\N	460	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1070	2024-11-25 09:08:11.88893+00	2024-11-25 09:08:11.88893+00	\N	460	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1071	2024-11-25 09:08:12.01349+00	2024-11-25 09:08:12.01349+00	\N	460	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1072	2024-11-25 09:08:24.606651+00	2024-11-25 09:08:24.606651+00	\N	461	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1073	2024-11-25 09:08:24.731985+00	2024-11-25 09:08:24.731985+00	\N	461	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1074	2024-11-25 09:08:29.776389+00	2024-11-25 09:08:29.776389+00	\N	461	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1075	2024-11-25 09:08:29.901112+00	2024-11-25 09:08:29.901112+00	\N	461	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1076	2024-11-25 09:18:38.162206+00	2024-11-25 09:18:38.162206+00	\N	692	order	http://holote.vn:8083/image-storage/IMG1732526317027413284.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1077	2024-11-25 09:19:53.723668+00	2024-11-25 09:19:53.723668+00	\N	692	order	http://holote.vn:8083/image-storage/IMG1732526392456181408.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1078	2024-11-25 09:29:02.508429+00	2024-11-25 09:29:02.508429+00	\N	693	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1079	2024-11-25 09:29:02.633639+00	2024-11-25 09:29:02.633639+00	\N	693	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1080	2024-11-25 09:29:17.758901+00	2024-11-25 09:29:17.758901+00	\N	693	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1081	2024-11-25 09:29:17.883764+00	2024-11-25 09:29:17.883764+00	\N	693	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1082	2024-11-25 09:53:28.345635+00	2024-11-25 09:53:28.345635+00	\N	694	order	http://holote.vn:8083/image-storage/IMG1732528407159807356.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1083	2024-11-25 09:53:52.813614+00	2024-11-25 09:53:52.813614+00	\N	694	order	http://holote.vn:8083/image-storage/IMG1732528431667354738.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1084	2024-11-25 10:00:51.2997+00	2024-11-25 10:00:51.2997+00	\N	431	vehicle	http://holote.vn:8083/image-storage/IMG1732528850124405629.jpeg	create_vehicle_image	\N	\N	\N
1085	2024-11-25 10:09:16.595939+00	2024-11-25 10:09:16.595939+00	\N	696	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1086	2024-11-25 10:09:16.720445+00	2024-11-25 10:09:16.720445+00	\N	696	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1087	2024-11-25 10:09:25.369528+00	2024-11-25 10:09:25.369528+00	\N	696	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1088	2024-11-25 10:09:25.493124+00	2024-11-25 10:09:25.493124+00	\N	696	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1089	2024-11-26 02:13:32.881871+00	2024-11-26 02:13:32.881871+00	\N	462	log_order	http://holote.vn:8083/image-storage/IMG1732587211285604906.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1090	2024-11-26 02:13:53.358867+00	2024-11-26 02:13:53.358867+00	\N	462	log_order	http://holote.vn:8083/image-storage/IMG1732587231405775743.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1091	2024-11-26 03:49:50.044555+00	2024-11-26 03:49:50.044555+00	\N	432	vehicle	http://holote.vn:8083/image-storage/IMG1732592988718080423.jpeg	create_vehicle_image	\N	\N	\N
1092	2024-11-26 04:44:25.567692+00	2024-11-26 04:44:25.567692+00	\N	463	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1093	2024-11-26 04:44:25.692336+00	2024-11-26 04:44:25.692336+00	\N	463	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1094	2024-11-26 06:24:33.563272+00	2024-11-26 06:24:33.563272+00	\N	433	vehicle	http://holote.vn:8083/image-storage/IMG1732602272212875668.jpeg	create_vehicle_image	\N	\N	\N
1095	2024-11-26 06:34:50.2194+00	2024-11-26 06:34:50.2194+00	\N	434	vehicle	http://holote.vn:8083/image-storage/IMG1732602888811015045.jpeg	create_vehicle_image	\N	\N	\N
1096	2024-11-26 06:45:14.992724+00	2024-11-26 06:45:14.992724+00	\N	700	order	http://holote.vn:8083/image-storage/IMG1732603513573231243.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1097	2024-11-26 06:48:06.383297+00	2024-11-26 06:48:06.383297+00	\N	700	order	http://holote.vn:8083/image-storage/IMG1732603685049846568.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1098	2024-11-26 07:15:00.911539+00	2024-11-26 07:15:00.911539+00	\N	464	log_order	http://holote.vn:8083/image-storage/IMG1732605299341860435.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1099	2024-11-26 07:20:30.089534+00	2024-11-26 07:20:30.089534+00	\N	464	log_order	http://holote.vn:8083/image-storage/IMG1732605628170989842.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1100	2024-11-26 07:20:57.650697+00	2024-11-26 07:20:57.650697+00	\N	465	log_order	http://holote.vn:8083/image-storage/IMG1732605656099011499.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1101	2024-11-26 07:21:17.069602+00	2024-11-26 07:21:17.069602+00	\N	465	log_order	http://holote.vn:8083/image-storage/IMG1732605675241827299.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1102	2024-11-26 07:21:34.727933+00	2024-11-26 07:21:34.727933+00	\N	466	log_order	http://holote.vn:8083/image-storage/IMG1732605693024611326.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1103	2024-11-26 07:21:52.496117+00	2024-11-26 07:21:52.496117+00	\N	466	log_order	http://holote.vn:8083/image-storage/IMG1732605710582461689.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1104	2024-11-26 07:22:11.423978+00	2024-11-26 07:22:11.423978+00	\N	467	log_order	http://holote.vn:8083/image-storage/IMG1732605729616934665.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1105	2024-11-26 07:22:31.074968+00	2024-11-26 07:22:31.074968+00	\N	467	log_order	http://holote.vn:8083/image-storage/IMG1732605749186645531.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1106	2024-11-26 07:24:27.166391+00	2024-11-26 07:24:27.166391+00	\N	468	log_order	http://holote.vn:8083/image-storage/IMG1732605865449476214.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1107	2024-11-26 07:24:47.38714+00	2024-11-26 07:24:47.38714+00	\N	468	log_order	http://holote.vn:8083/image-storage/IMG1732605885565649802.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1108	2024-11-26 07:32:38.149926+00	2024-11-26 07:32:38.149926+00	\N	472	log_order	http://holote.vn:8083/image-storage/IMG1732606356601202283.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1109	2024-11-26 07:32:56.777205+00	2024-11-26 07:32:56.777205+00	\N	472	log_order	http://holote.vn:8083/image-storage/IMG1732606375039443705.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1110	2024-11-26 07:36:29.520369+00	2024-11-26 07:36:29.520369+00	\N	473	log_order	http://holote.vn:8083/image-storage/IMG1732606587966508859.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1111	2024-11-26 07:36:51.062353+00	2024-11-26 07:36:51.062353+00	\N	473	log_order	http://holote.vn:8083/image-storage/IMG1732606609305861882.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1112	2024-11-26 07:39:56.3454+00	2024-11-26 07:39:56.3454+00	\N	435	vehicle	http://holote.vn:8083/image-storage/IMG1732606795037897983.jpeg	create_vehicle_image	\N	\N	\N
1113	2024-11-26 07:46:22.130945+00	2024-11-26 07:46:22.130945+00	\N	436	vehicle	http://holote.vn:8083/image-storage/IMG1732607180873863020.jpeg	create_vehicle_image	\N	\N	\N
1114	2024-11-26 07:47:36.196163+00	2024-11-26 07:47:36.196163+00	\N	693	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1115	2024-11-26 07:47:36.328284+00	2024-11-26 07:47:36.328284+00	\N	693	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1116	2024-11-26 07:51:21.335366+00	2024-11-26 07:51:21.335366+00	\N	689	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1117	2024-11-26 07:51:21.466063+00	2024-11-26 07:51:21.466063+00	\N	689	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1118	2024-11-26 07:55:28.879637+00	2024-11-26 07:55:28.879637+00	\N	692	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1119	2024-11-26 07:55:29.005047+00	2024-11-26 07:55:29.005047+00	\N	692	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1120	2024-11-26 07:57:20.148042+00	2024-11-26 07:57:20.148042+00	\N	474	log_order	http://holote.vn:8083/image-storage/IMG1732607838521569795.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1121	2024-11-26 07:59:25.178735+00	2024-11-26 07:59:25.178735+00	\N	474	log_order	http://holote.vn:8083/image-storage/IMG1732607963208610479.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1122	2024-11-26 08:01:00.809982+00	2024-11-26 08:01:00.809982+00	\N	475	log_order	http://holote.vn:8083/image-storage/IMG1732608059167715073.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1123	2024-11-26 08:01:35.100031+00	2024-11-26 08:01:35.100031+00	\N	475	log_order	http://holote.vn:8083/image-storage/IMG1732608093109039858.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1124	2024-11-26 08:04:02.526779+00	2024-11-26 08:04:02.526779+00	\N	476	log_order	http://holote.vn:8083/image-storage/IMG1732608240973288476.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1125	2024-11-26 08:04:34.622245+00	2024-11-26 08:04:34.622245+00	\N	476	log_order	http://holote.vn:8083/image-storage/IMG1732608272827262140.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1126	2024-11-26 08:12:54.306983+00	2024-11-26 08:12:54.306983+00	\N	700	order	http://placeimg.com/640/480	admin_confirm_order_unpaid_image	\N	\N	\N
1127	2024-11-26 08:12:54.430661+00	2024-11-26 08:12:54.430661+00	\N	700	order	http://placeimg.com/640/480	admin_confirm_order_unpaid_image	\N	\N	\N
1128	2024-11-26 08:18:14.465865+00	2024-11-26 08:18:14.465865+00	\N	696	order	http://placeimg.com/640/480	admin_confirm_order_unpaid_image	\N	\N	\N
1129	2024-11-26 08:18:14.590007+00	2024-11-26 08:18:14.590007+00	\N	696	order	http://placeimg.com/640/480	admin_confirm_order_unpaid_image	\N	\N	\N
1130	2024-11-26 08:19:49.335745+00	2024-11-26 08:19:49.335745+00	\N	701	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1131	2024-11-26 08:19:49.44437+00	2024-11-26 08:19:49.44437+00	\N	701	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1132	2024-11-26 09:04:18.708055+00	2024-11-26 09:04:18.708055+00	\N	326	order	http://placeimg.com/640/480	admin_confirm_order_unpaid_image	\N	\N	\N
1133	2024-11-26 09:04:18.823241+00	2024-11-26 09:04:18.823241+00	\N	326	order	http://placeimg.com/640/480	admin_confirm_order_unpaid_image	\N	\N	\N
1134	2024-11-26 09:04:55.395717+00	2024-11-26 09:04:55.395717+00	\N	326	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1135	2024-11-26 09:04:55.502273+00	2024-11-26 09:04:55.502273+00	\N	326	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1136	2024-11-26 09:39:05.712417+00	2024-11-26 09:39:05.712417+00	\N	326	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1137	2024-11-26 09:39:05.822132+00	2024-11-26 09:39:05.822132+00	\N	326	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1138	2024-11-26 09:39:18.009057+00	2024-11-26 09:39:18.009057+00	\N	326	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1139	2024-11-26 09:39:18.117349+00	2024-11-26 09:39:18.117349+00	\N	326	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1140	2024-11-26 10:02:52.243522+00	2024-11-26 10:02:52.243522+00	\N	677	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1141	2024-11-26 10:02:52.368806+00	2024-11-26 10:02:52.368806+00	\N	677	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1142	2024-11-26 10:12:29.506637+00	2024-11-26 10:12:29.506637+00	\N	326	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1143	2024-11-26 10:12:29.621215+00	2024-11-26 10:12:29.621215+00	\N	326	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1144	2024-11-26 10:25:28.966995+00	2024-11-26 10:25:28.966995+00	\N	696	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1145	2024-11-26 10:25:29.09243+00	2024-11-26 10:25:29.09243+00	\N	696	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1146	2024-11-26 10:27:07.884789+00	2024-11-26 10:27:07.884789+00	\N	700	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1147	2024-11-26 10:27:08.010154+00	2024-11-26 10:27:08.010154+00	\N	700	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1148	2024-11-27 02:01:40.001279+00	2024-11-27 02:01:40.001279+00	\N	701	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1149	2024-11-27 02:01:40.127668+00	2024-11-27 02:01:40.127668+00	\N	701	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1150	2024-11-27 02:04:51.364495+00	2024-11-27 02:04:51.364495+00	\N	701	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1151	2024-11-27 02:04:51.490397+00	2024-11-27 02:04:51.490397+00	\N	701	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1152	2024-11-27 02:12:41.530258+00	2024-11-27 02:12:41.530258+00	\N	694	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1153	2024-11-27 02:12:41.657383+00	2024-11-27 02:12:41.657383+00	\N	694	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1154	2024-11-27 02:43:55.613511+00	2024-11-27 02:43:55.613511+00	\N	706	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1155	2024-11-27 02:43:55.739048+00	2024-11-27 02:43:55.739048+00	\N	706	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1156	2024-11-27 02:44:28.141177+00	2024-11-27 02:44:28.141177+00	\N	706	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1157	2024-11-27 02:44:28.266889+00	2024-11-27 02:44:28.266889+00	\N	706	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1158	2024-11-27 02:45:58.485164+00	2024-11-27 02:45:58.485164+00	\N	706	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1159	2024-11-27 02:45:58.61049+00	2024-11-27 02:45:58.61049+00	\N	706	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1160	2024-11-27 03:10:46.068985+00	2024-11-27 03:10:46.068985+00	\N	707	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1161	2024-11-27 03:10:46.196112+00	2024-11-27 03:10:46.196112+00	\N	707	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1162	2024-11-27 03:10:48.036842+00	2024-11-27 03:10:48.036842+00	\N	707	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1163	2024-11-27 03:10:48.162817+00	2024-11-27 03:10:48.162817+00	\N	707	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1164	2024-11-27 03:11:26.104231+00	2024-11-27 03:11:26.104231+00	\N	707	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1165	2024-11-27 03:11:26.230635+00	2024-11-27 03:11:26.230635+00	\N	707	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1166	2024-11-27 03:43:13.713824+00	2024-11-27 03:43:13.713824+00	\N	437	vehicle	http://holote.vn:8083/image-storage/IMG1732678992249326403.jpeg	create_vehicle_image	\N	\N	\N
1167	2024-11-27 03:44:55.352004+00	2024-11-27 03:44:55.352004+00	\N	438	vehicle	http://holote.vn:8083/image-storage/IMG1732678992249326403.jpeg	create_vehicle_image	\N	\N	\N
1168	2024-11-27 06:43:45.327397+00	2024-11-27 06:43:45.327397+00	\N	484	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1169	2024-11-27 06:43:45.453093+00	2024-11-27 06:43:45.453093+00	\N	484	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1170	2024-11-27 06:44:17.014983+00	2024-11-27 06:44:17.014983+00	\N	484	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1171	2024-11-27 06:44:17.138915+00	2024-11-27 06:44:17.138915+00	\N	484	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1172	2024-11-27 06:45:23.644842+00	2024-11-27 06:45:23.644842+00	\N	485	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1173	2024-11-27 06:45:23.769033+00	2024-11-27 06:45:23.769033+00	\N	485	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1174	2024-11-27 06:45:34.584432+00	2024-11-27 06:45:34.584432+00	\N	485	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1175	2024-11-27 06:45:34.709419+00	2024-11-27 06:45:34.709419+00	\N	485	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1176	2024-11-27 07:14:27.169281+00	2024-11-27 07:14:27.169281+00	\N	486	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1177	2024-11-27 07:14:27.2944+00	2024-11-27 07:14:27.2944+00	\N	486	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1178	2024-11-27 07:14:38.643541+00	2024-11-27 07:14:38.643541+00	\N	486	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1179	2024-11-27 07:14:38.768073+00	2024-11-27 07:14:38.768073+00	\N	486	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1180	2024-11-27 07:33:40.325759+00	2024-11-27 07:33:40.325759+00	\N	487	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1188	2024-11-27 07:52:03.475919+00	2024-11-27 07:52:03.475919+00	\N	489	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1189	2024-11-27 07:52:03.601258+00	2024-11-27 07:52:03.601258+00	\N	489	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1190	2024-11-27 07:52:22.921215+00	2024-11-27 07:52:22.921215+00	\N	489	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1191	2024-11-27 07:52:23.045875+00	2024-11-27 07:52:23.045875+00	\N	489	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1204	2024-11-27 09:43:12.837956+00	2024-11-27 09:43:12.837956+00	\N	501	log_order	http://holote.vn:8083/image-storage/IMG1732700591041208030.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1205	2024-11-27 09:44:45.740518+00	2024-11-27 09:44:45.740518+00	\N	501	log_order	http://holote.vn:8083/image-storage/IMG1732700683706701182.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1206	2024-11-27 20:10:35.962738+00	2024-11-27 20:10:35.962738+00	\N	704	order	http://holote.vn:8083/image-storage/IMG1732738234394610230.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1207	2024-11-27 20:11:38.988804+00	2024-11-27 20:11:38.988804+00	\N	704	order	http://holote.vn:8083/image-storage/IMG1732738297461009758.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1208	2024-11-28 01:39:25.331005+00	2024-11-28 01:39:25.331005+00	\N	502	log_order	http://holote.vn:8083/image-storage/IMG1732757963417486680.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1209	2024-11-28 01:39:48.038365+00	2024-11-28 01:39:48.038365+00	\N	502	log_order	http://holote.vn:8083/image-storage/IMG1732757985744594778.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1210	2024-11-28 01:40:09.363394+00	2024-11-28 01:40:09.363394+00	\N	503	log_order	http://holote.vn:8083/image-storage/IMG1732758007511728611.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1211	2024-11-28 02:17:14.454635+00	2024-11-28 02:17:14.454635+00	\N	463	log_order	http://holote.vn:8083/image-storage/IMG1732760232181862477.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1212	2024-11-28 02:19:37.677071+00	2024-11-28 02:19:37.677071+00	\N	504	log_order	http://holote.vn:8083/image-storage/IMG1732760375709206345.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1213	2024-11-28 02:26:27.416007+00	2024-11-28 02:26:27.416007+00	\N	504	log_order	http://holote.vn:8083/image-storage/IMG1732760785061899389.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1214	2024-11-28 02:26:27.540902+00	2024-11-28 02:26:27.540902+00	\N	504	log_order	http://holote.vn:8083/image-storage/IMG1732760785061887697.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1215	2024-11-28 02:38:56.988546+00	2024-11-28 02:38:56.988546+00	\N	505	log_order	http://holote.vn:8083/image-storage/IMG1732761535125056135.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1216	2024-11-28 02:39:24.498836+00	2024-11-28 02:39:24.498836+00	\N	505	log_order	http://holote.vn:8083/image-storage/IMG1732761562284613300.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1217	2024-11-28 02:46:53.262269+00	2024-11-28 02:46:53.262269+00	\N	506	log_order	http://holote.vn:8083/image-storage/IMG1732762011318005032.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1218	2024-11-28 02:53:01.078251+00	2024-11-28 02:53:01.078251+00	\N	506	log_order	http://holote.vn:8083/image-storage/IMG1732762378811455753.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1219	2024-11-28 02:53:20.087697+00	2024-11-28 02:53:20.087697+00	\N	507	log_order	http://holote.vn:8083/image-storage/IMG1732762398154055287.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1196	2024-11-27 07:54:13.283721+00	2024-11-27 07:54:13.283721+00	\N	491	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1184	2024-11-27 07:36:21.330471+00	2024-11-27 07:36:21.330471+00	\N	488	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1187	2024-11-27 07:36:32.856848+00	2024-11-27 07:36:32.856848+00	\N	540	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1181	2024-11-27 07:33:40.449697+00	2024-11-27 07:33:40.449697+00	\N	487	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1225	2024-11-28 03:47:52.781334+00	2024-11-28 03:47:52.781334+00	\N	541	log_order	http://holote.vn:8083/image-storage/IMG1732765670511923398.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1182	2024-11-27 07:33:51.490587+00	2024-11-27 07:33:51.490587+00	\N	487	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1183	2024-11-27 07:33:51.614986+00	2024-11-27 07:33:51.614986+00	\N	487	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1186	2024-11-27 07:36:32.732644+00	2024-11-27 07:36:32.732644+00	\N	488	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1185	2024-11-27 07:36:21.454541+00	2024-11-27 07:36:21.454541+00	\N	488	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1227	2024-11-28 03:52:27.019916+00	2024-11-28 03:52:27.019916+00	\N	510	log_order	http://holote.vn:8083/image-storage/IMG1732765944889037996.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1228	2024-11-28 04:02:11.933077+00	2024-11-28 04:02:11.933077+00	\N	511	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1229	2024-11-28 04:02:12.05881+00	2024-11-28 04:02:12.05881+00	\N	511	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1230	2024-11-28 04:02:30.931862+00	2024-11-28 04:02:30.931862+00	\N	511	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1231	2024-11-28 04:02:31.057041+00	2024-11-28 04:02:31.057041+00	\N	511	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1232	2024-11-28 04:03:04.081943+00	2024-11-28 04:03:04.081943+00	\N	512	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1233	2024-11-28 04:03:04.207479+00	2024-11-28 04:03:04.207479+00	\N	512	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1234	2024-11-28 04:03:12.182798+00	2024-11-28 04:03:12.182798+00	\N	512	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1235	2024-11-28 04:03:12.310634+00	2024-11-28 04:03:12.310634+00	\N	512	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1236	2024-11-28 04:20:56.462072+00	2024-11-28 04:20:56.462072+00	\N	514	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1237	2024-11-28 04:20:56.58795+00	2024-11-28 04:20:56.58795+00	\N	514	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1238	2024-11-28 04:21:13.86817+00	2024-11-28 04:21:13.86817+00	\N	514	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1239	2024-11-28 04:21:13.992216+00	2024-11-28 04:21:13.992216+00	\N	514	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1240	2024-11-28 04:53:08.911865+00	2024-11-28 04:53:08.911865+00	\N	520	log_order	http://holote.vn:8083/image-storage/IMG1732769586937396222.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1241	2024-11-28 04:53:30.572691+00	2024-11-28 04:53:30.572691+00	\N	520	log_order	http://holote.vn:8083/image-storage/IMG1732769608271944565.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1242	2024-11-28 04:57:55.527797+00	2024-11-28 04:57:55.527797+00	\N	521	log_order	http://holote.vn:8083/image-storage/IMG1732769873575968999.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1243	2024-11-28 04:58:17.12643+00	2024-11-28 04:58:17.12643+00	\N	521	log_order	http://holote.vn:8083/image-storage/IMG1732769894868667748.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1244	2024-11-28 04:58:49.993775+00	2024-11-28 04:58:49.993775+00	\N	522	log_order	http://holote.vn:8083/image-storage/IMG1732769928235661897.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1245	2024-11-28 04:59:07.526304+00	2024-11-28 04:59:07.526304+00	\N	522	log_order	http://holote.vn:8083/image-storage/IMG1732769945393559301.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1246	2024-11-28 06:02:55.199417+00	2024-11-28 06:02:55.199417+00	\N	523	log_order	http://holote.vn:8083/image-storage/IMG1732773773301915700.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1247	2024-11-28 06:03:13.95057+00	2024-11-28 06:03:13.95057+00	\N	523	log_order	http://holote.vn:8083/image-storage/IMG1732773791775443663.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1248	2024-11-28 06:03:31.97496+00	2024-11-28 06:03:31.97496+00	\N	524	log_order	http://holote.vn:8083/image-storage/IMG1732773810120868251.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1249	2024-11-28 06:04:10.060584+00	2024-11-28 06:04:10.060584+00	\N	524	log_order	http://holote.vn:8083/image-storage/IMG1732773847912496027.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1250	2024-11-28 06:04:42.917827+00	2024-11-28 06:04:42.917827+00	\N	525	log_order	http://holote.vn:8083/image-storage/IMG1732773881065806022.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1251	2024-11-28 06:05:17.255839+00	2024-11-28 06:05:17.255839+00	\N	525	log_order	http://holote.vn:8083/image-storage/IMG1732773915010529706.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1252	2024-11-28 06:08:00.045178+00	2024-11-28 06:08:00.045178+00	\N	526	log_order	http://holote.vn:8083/image-storage/IMG1732774078270703355.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1253	2024-11-28 06:08:32.5105+00	2024-11-28 06:08:32.5105+00	\N	526	log_order	http://holote.vn:8083/image-storage/IMG1732774110450049057.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1254	2024-11-28 06:23:33.141433+00	2024-11-28 06:23:33.141433+00	\N	718	order	http://holote.vn:8083/image-storage/IMG1732775011447283911.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1255	2024-11-28 06:23:52.655861+00	2024-11-28 06:23:52.655861+00	\N	718	order	http://holote.vn:8083/image-storage/IMG1732775031058077283.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1256	2024-11-28 06:37:51.471851+00	2024-11-28 06:37:51.471851+00	\N	528	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1257	2024-11-28 06:37:51.598718+00	2024-11-28 06:37:51.598718+00	\N	528	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1258	2024-11-28 06:38:10.392434+00	2024-11-28 06:38:10.392434+00	\N	528	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1259	2024-11-28 06:38:10.518827+00	2024-11-28 06:38:10.518827+00	\N	528	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1260	2024-11-28 06:38:28.390824+00	2024-11-28 06:38:28.390824+00	\N	529	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1261	2024-11-28 06:38:28.517273+00	2024-11-28 06:38:28.517273+00	\N	529	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1262	2024-11-28 06:38:34.679703+00	2024-11-28 06:38:34.679703+00	\N	529	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1263	2024-11-28 06:38:34.805603+00	2024-11-28 06:38:34.805603+00	\N	529	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1264	2024-11-28 06:39:41.736364+00	2024-11-28 06:39:41.736364+00	\N	530	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1265	2024-11-28 06:39:41.86383+00	2024-11-28 06:39:41.86383+00	\N	530	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1266	2024-11-28 06:39:48.759648+00	2024-11-28 06:39:48.759648+00	\N	530	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1267	2024-11-28 06:39:48.887443+00	2024-11-28 06:39:48.887443+00	\N	530	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1268	2024-11-28 06:47:13.07179+00	2024-11-28 06:47:13.07179+00	\N	531	log_order	http://holote.vn:8083/image-storage/IMG1732776431011349721.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1269	2024-11-28 06:47:13.491584+00	2024-11-28 06:47:13.491584+00	\N	532	log_order	http://holote.vn:8083/image-storage/IMG1732776431419889283.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1270	2024-11-28 06:47:31.462983+00	2024-11-28 06:47:31.462983+00	\N	531	log_order	http://holote.vn:8083/image-storage/IMG1732776449113353112.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1271	2024-11-28 06:47:33.391711+00	2024-11-28 06:47:33.391711+00	\N	532	log_order	http://holote.vn:8083/image-storage/IMG1732776451285288014.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1272	2024-11-28 06:48:02.946002+00	2024-11-28 06:48:02.946002+00	\N	533	log_order	http://holote.vn:8083/image-storage/IMG1732776481064927365.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1273	2024-11-28 06:48:28.028597+00	2024-11-28 06:48:28.028597+00	\N	533	log_order	http://holote.vn:8083/image-storage/IMG1732776505786814066.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1274	2024-11-28 06:48:53.887532+00	2024-11-28 06:48:53.887532+00	\N	534	log_order	http://holote.vn:8083/image-storage/IMG1732776532002912563.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1275	2024-11-28 06:48:56.827857+00	2024-11-28 06:48:56.827857+00	\N	535	log_order	http://holote.vn:8083/image-storage/IMG1732776534954607933.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1276	2024-11-28 06:49:14.748353+00	2024-11-28 06:49:14.748353+00	\N	535	log_order	http://holote.vn:8083/image-storage/IMG1732776552519918908.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1277	2024-11-28 06:49:45.543386+00	2024-11-28 06:49:45.543386+00	\N	534	log_order	http://holote.vn:8083/image-storage/IMG1732776583359925088.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1278	2024-11-28 06:50:16.956887+00	2024-11-28 06:50:16.956887+00	\N	536	log_order	http://holote.vn:8083/image-storage/IMG1732776615082329586.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1279	2024-11-28 06:50:51.600316+00	2024-11-28 06:50:51.600316+00	\N	537	log_order	http://holote.vn:8083/image-storage/IMG1732776649683468764.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1280	2024-11-28 06:57:10.257365+00	2024-11-28 06:57:10.257365+00	\N	536	log_order	http://holote.vn:8083/image-storage/IMG1732777028008407524.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1281	2024-11-28 07:18:51.603017+00	2024-11-28 07:18:51.603017+00	\N	539	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1282	2024-11-28 07:18:51.729616+00	2024-11-28 07:18:51.729616+00	\N	539	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1283	2024-11-28 07:19:19.780905+00	2024-11-28 07:19:19.780905+00	\N	539	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1284	2024-11-28 07:19:19.907023+00	2024-11-28 07:19:19.907023+00	\N	539	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1285	2024-11-28 07:20:09.442537+00	2024-11-28 07:20:09.442537+00	\N	540	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1286	2024-11-28 07:20:09.567852+00	2024-11-28 07:20:09.567852+00	\N	540	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1287	2024-11-28 07:20:28.246944+00	2024-11-28 07:20:28.246944+00	\N	540	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1288	2024-11-28 07:20:28.371898+00	2024-11-28 07:20:28.371898+00	\N	540	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1289	2024-11-28 07:24:40.3348+00	2024-11-28 07:24:40.3348+00	\N	541	log_order	http://holote.vn:8083/image-storage/IMG1732778678438797692.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1290	2024-11-28 07:25:10.935812+00	2024-11-28 07:25:10.935812+00	\N	541	log_order	http://holote.vn:8083/image-storage/IMG1732778708778338535.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1291	2024-11-28 07:42:09.445999+00	2024-11-28 07:42:09.445999+00	\N	542	log_order	http://holote.vn:8083/image-storage/IMG1732779727591019488.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1292	2024-11-28 07:42:27.085978+00	2024-11-28 07:42:27.085978+00	\N	542	log_order	http://holote.vn:8083/image-storage/IMG1732779744918064993.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1293	2024-11-28 07:57:05.210809+00	2024-11-28 07:57:05.210809+00	\N	721	order	http://holote.vn:8083/image-storage/IMG1732780623518987519.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1294	2024-11-28 07:57:55.101175+00	2024-11-28 07:57:55.101175+00	\N	721	order	http://holote.vn:8083/image-storage/IMG1732780673427753468.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1295	2024-11-28 08:28:55.008688+00	2024-11-28 08:28:55.008688+00	\N	543	log_order	http://holote.vn:8083/image-storage/IMG1732782532988119290.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1296	2024-11-28 08:29:20.822543+00	2024-11-28 08:29:20.822543+00	\N	543	log_order	http://holote.vn:8083/image-storage/IMG1732782558571597965.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1297	2024-11-28 08:29:40.214004+00	2024-11-28 08:29:40.214004+00	\N	544	log_order	http://holote.vn:8083/image-storage/IMG1732782578225734550.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1298	2024-11-28 08:29:59.502277+00	2024-11-28 08:29:59.502277+00	\N	544	log_order	http://holote.vn:8083/image-storage/IMG1732782597122407796.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1299	2024-11-28 08:31:03.290432+00	2024-11-28 08:31:03.290432+00	\N	545	log_order	http://holote.vn:8083/image-storage/IMG1732782661296067389.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1300	2024-11-28 08:31:47.682195+00	2024-11-28 08:31:47.682195+00	\N	545	log_order	http://holote.vn:8083/image-storage/IMG1732782705351724338.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1301	2024-11-28 08:33:56.602504+00	2024-11-28 08:33:56.602504+00	\N	546	log_order	http://holote.vn:8083/image-storage/IMG1732782834755148647.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1302	2024-11-28 08:35:14.140189+00	2024-11-28 08:35:14.140189+00	\N	546	log_order	http://holote.vn:8083/image-storage/IMG1732782911929398759.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1303	2024-11-28 08:36:01.198656+00	2024-11-28 08:36:01.198656+00	\N	547	log_order	http://holote.vn:8083/image-storage/IMG1732782959315868490.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1304	2024-11-28 08:36:19.42426+00	2024-11-28 08:36:19.42426+00	\N	547	log_order	http://holote.vn:8083/image-storage/IMG1732782977248316835.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1305	2024-11-28 08:40:35.685046+00	2024-11-28 08:40:35.685046+00	\N	723	order	http://holote.vn:8083/image-storage/IMG1732783233924579630.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1306	2024-11-28 08:41:53.198771+00	2024-11-28 08:41:53.198771+00	\N	723	order	http://holote.vn:8083/image-storage/IMG1732783311470712824.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1307	2024-11-28 08:49:52.285148+00	2024-11-28 08:49:52.285148+00	\N	548	log_order	http://holote.vn:8083/image-storage/IMG1732783790339423826.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1308	2024-11-28 08:50:12.024383+00	2024-11-28 08:50:12.024383+00	\N	548	log_order	http://holote.vn:8083/image-storage/IMG1732783809726187777.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1309	2024-11-28 08:50:43.244822+00	2024-11-28 08:50:43.244822+00	\N	549	log_order	http://holote.vn:8083/image-storage/IMG1732783841289891033.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1310	2024-11-28 08:51:03.833602+00	2024-11-28 08:51:03.833602+00	\N	549	log_order	http://holote.vn:8083/image-storage/IMG1732783861566538294.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1311	2024-11-28 08:52:39.34712+00	2024-11-28 08:52:39.34712+00	\N	550	log_order	http://holote.vn:8083/image-storage/IMG1732783957422081411.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1312	2024-11-28 08:53:01.707173+00	2024-11-28 08:53:01.707173+00	\N	550	log_order	http://holote.vn:8083/image-storage/IMG1732783979587689875.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1313	2024-11-28 08:56:52.283486+00	2024-11-28 08:56:52.283486+00	\N	724	project_order	https://murphy.name	admin_confirm_order_paid_image	\N	\N	\N
1314	2024-11-28 08:58:57.297651+00	2024-11-28 08:58:57.297651+00	\N	551	log_order	http://holote.vn:8083/image-storage/IMG1732784335308770876.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1315	2024-11-28 08:59:29.038222+00	2024-11-28 08:59:29.038222+00	\N	551	log_order	http://holote.vn:8083/image-storage/IMG1732784366728025193.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1316	2024-11-28 08:59:49.274956+00	2024-11-28 08:59:49.274956+00	\N	552	log_order	http://holote.vn:8083/image-storage/IMG1732784387336617319.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1317	2024-11-28 09:00:09.849307+00	2024-11-28 09:00:09.849307+00	\N	552	log_order	http://holote.vn:8083/image-storage/IMG1732784407596193099.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1318	2024-11-28 09:01:21.477602+00	2024-11-28 09:01:21.477602+00	\N	553	log_order	http://holote.vn:8083/image-storage/IMG1732784479570448333.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1319	2024-11-28 09:01:43.948981+00	2024-11-28 09:01:43.948981+00	\N	553	log_order	http://holote.vn:8083/image-storage/IMG1732784501807885848.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1320	2024-11-28 09:02:44.57363+00	2024-11-28 09:02:44.57363+00	\N	725	project_order	https://jeromy.name	admin_confirm_order_paid_image	\N	\N	\N
1321	2024-11-28 09:04:17.352424+00	2024-11-28 09:04:17.352424+00	\N	554	log_order	http://holote.vn:8083/image-storage/IMG1732784655369597019.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1322	2024-11-28 09:04:36.009021+00	2024-11-28 09:04:36.009021+00	\N	554	log_order	http://holote.vn:8083/image-storage/IMG1732784673768572122.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1323	2024-11-28 09:04:53.217325+00	2024-11-28 09:04:53.217325+00	\N	555	log_order	http://holote.vn:8083/image-storage/IMG1732784691245612205.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1324	2024-11-28 09:05:13.187374+00	2024-11-28 09:05:13.187374+00	\N	555	log_order	http://holote.vn:8083/image-storage/IMG1732784710887752048.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1325	2024-11-28 09:06:39.820752+00	2024-11-28 09:06:39.820752+00	\N	556	log_order	http://holote.vn:8083/image-storage/IMG1732784797899985621.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1326	2024-11-28 09:06:57.919542+00	2024-11-28 09:06:57.919542+00	\N	556	log_order	http://holote.vn:8083/image-storage/IMG1732784815813119116.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1327	2024-11-28 09:08:30.572492+00	2024-11-28 09:08:30.572492+00	\N	726	project_order	https://audrey.org	admin_confirm_order_paid_image	\N	\N	\N
1328	2024-11-29 02:13:31.92328+00	2024-11-29 02:13:31.92328+00	\N	557	log_order	http://holote.vn:8083/image-storage/IMG1732846409809658344.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1329	2024-11-29 02:13:50.061823+00	2024-11-29 02:13:50.061823+00	\N	557	log_order	http://holote.vn:8083/image-storage/IMG1732846427753291334.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1330	2024-11-29 02:14:33.656113+00	2024-11-29 02:14:33.656113+00	\N	558	log_order	http://holote.vn:8083/image-storage/IMG1732846471599692295.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1331	2024-11-29 02:14:51.155999+00	2024-11-29 02:14:51.155999+00	\N	558	log_order	http://holote.vn:8083/image-storage/IMG1732846488830254629.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1332	2024-11-29 03:13:46.302275+00	2024-11-29 03:13:46.302275+00	\N	559	log_order	http://holote.vn:8083/image-storage/IMG1732850024340997519.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1333	2024-11-29 03:14:06.70084+00	2024-11-29 03:14:06.70084+00	\N	559	log_order	http://holote.vn:8083/image-storage/IMG1732850044370461346.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1334	2024-11-29 03:27:45.775142+00	2024-11-29 03:27:45.775142+00	\N	727	project_order	https://denis.com	admin_confirm_order_paid_image	\N	\N	\N
1335	2024-11-29 04:18:31.509064+00	2024-11-29 04:18:31.509064+00	\N	729	order	http://holote.vn:8083/image-storage/IMG1732853909601156027.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1336	2024-11-29 04:18:51.237345+00	2024-11-29 04:18:51.237345+00	\N	729	order	http://holote.vn:8083/image-storage/IMG1732853929429768438.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1337	2024-11-29 06:52:02.250315+00	2024-11-29 06:52:02.250315+00	\N	560	log_order	http://holote.vn:8083/image-storage/IMG1732863120133537942.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1338	2024-11-29 06:52:19.982138+00	2024-11-29 06:52:19.982138+00	\N	560	log_order	http://holote.vn:8083/image-storage/IMG1732863137543733000.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1339	2024-11-29 06:53:11.224569+00	2024-11-29 06:53:11.224569+00	\N	561	log_order	http://holote.vn:8083/image-storage/IMG1732863189091102822.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1340	2024-11-29 06:53:29.778818+00	2024-11-29 06:53:29.778818+00	\N	561	log_order	http://holote.vn:8083/image-storage/IMG1732863207312825294.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1341	2024-11-29 06:55:03.533099+00	2024-11-29 06:55:03.533099+00	\N	562	log_order	http://holote.vn:8083/image-storage/IMG1732863301500867259.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1342	2024-11-29 06:55:22.225179+00	2024-11-29 06:55:22.225179+00	\N	562	log_order	http://holote.vn:8083/image-storage/IMG1732863319917413603.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1343	2024-11-29 07:02:07.258847+00	2024-11-29 07:02:07.258847+00	\N	731	project_order	http://hettie.biz	admin_confirm_order_paid_image	\N	\N	\N
1350	2024-11-29 07:14:24.174625+00	2024-11-29 07:14:24.174625+00	\N	732	project_order	http://nolan.info	admin_confirm_order_paid_image	\N	\N	\N
1351	2024-11-29 07:53:38.656558+00	2024-11-29 07:53:38.656558+00	\N	734	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1352	2024-11-29 07:53:38.781437+00	2024-11-29 07:53:38.781437+00	\N	734	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1353	2024-11-29 07:53:44.739452+00	2024-11-29 07:53:44.739452+00	\N	734	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1354	2024-11-29 07:53:44.864636+00	2024-11-29 07:53:44.864636+00	\N	734	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1355	2024-11-29 07:54:36.670956+00	2024-11-29 07:54:36.670956+00	\N	734	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1356	2024-11-29 07:54:36.79602+00	2024-11-29 07:54:36.79602+00	\N	734	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1357	2024-11-29 08:00:28.251051+00	2024-11-29 08:00:28.251051+00	\N	735	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1358	2024-11-29 08:00:28.376453+00	2024-11-29 08:00:28.376453+00	\N	735	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1359	2024-11-29 08:00:32.418431+00	2024-11-29 08:00:32.418431+00	\N	735	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1360	2024-11-29 08:00:32.543343+00	2024-11-29 08:00:32.543343+00	\N	735	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1361	2024-11-29 08:00:41.936322+00	2024-11-29 08:00:41.936322+00	\N	735	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1362	2024-11-29 08:00:42.060487+00	2024-11-29 08:00:42.060487+00	\N	735	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1363	2024-11-29 08:33:33.001715+00	2024-11-29 08:33:33.001715+00	\N	736	order	http://holote.vn:8083/image-storage/IMG1732869211036304138.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1364	2024-11-29 08:33:52.877233+00	2024-11-29 08:33:52.877233+00	\N	736	order	http://holote.vn:8083/image-storage/IMG1732869231029914329.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1365	2024-11-29 08:37:35.29768+00	2024-11-29 08:37:35.29768+00	\N	735	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1366	2024-11-29 08:37:39.56498+00	2024-11-29 08:37:39.56498+00	\N	735	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1367	2024-11-29 08:39:17.182887+00	2024-11-29 08:39:17.182887+00	\N	735	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1368	2024-11-29 08:39:17.289172+00	2024-11-29 08:39:17.289172+00	\N	735	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1369	2024-11-29 08:40:39.115891+00	2024-11-29 08:40:39.115891+00	\N	735	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1370	2024-11-30 07:24:50.006144+00	2024-11-30 07:24:50.006144+00	\N	737	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1371	2024-11-30 07:24:50.132383+00	2024-11-30 07:24:50.132383+00	\N	737	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1372	2024-11-30 07:25:15.541904+00	2024-11-30 07:25:15.541904+00	\N	737	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1373	2024-11-30 07:25:15.66688+00	2024-11-30 07:25:15.66688+00	\N	737	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1374	2024-11-30 07:26:40.872799+00	2024-11-30 07:26:40.872799+00	\N	737	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1375	2024-11-30 07:26:40.998318+00	2024-11-30 07:26:40.998318+00	\N	737	order	http://placeimg.com/640/480	admin_confirm_order_paid_image	\N	\N	\N
1349	2024-11-29 07:13:10.140297+00	2024-11-29 07:13:10.140297+00	\N	566	log_order	http://holote.vn:8083/image-storage/IMG1732864387826577232.jpeg	log_order_weight_ticket_image_deliver	732	139	driver
1347	2024-11-29 07:11:28.124203+00	2024-11-29 07:11:28.124203+00	\N	565	log_order	http://holote.vn:8083/image-storage/IMG1732864285698485090.jpeg	log_order_weight_ticket_image_deliver	732	140	driver
1348	2024-11-29 07:12:51.313847+00	2024-11-29 07:12:51.313847+00	\N	566	log_order	http://holote.vn:8083/image-storage/IMG1732864369354957016.jpeg	log_order_weight_ticket_image_receive	732	139	driver
1345	2024-11-29 07:10:26.433555+00	2024-11-29 07:10:26.433555+00	\N	564	log_order	http://holote.vn:8083/image-storage/IMG1732864224023259028.jpeg	log_order_weight_ticket_image_deliver	732	139	driver
1380	2024-12-01 01:41:59.173553+00	2024-12-01 01:41:59.173553+00	\N	741	order	http://holote.vn:8083/image-storage/IMG1733017317052850440.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1381	2024-12-01 01:42:21.483068+00	2024-12-01 01:42:21.483068+00	\N	741	order	http://holote.vn:8083/image-storage/IMG1733017339382959420.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1382	2024-12-01 01:47:21.731369+00	2024-12-01 01:47:21.731369+00	\N	742	order	http://holote.vn:8083/image-storage/IMG1733017639601245626.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1383	2024-12-01 03:20:51.254429+00	2024-12-01 03:20:51.254429+00	\N	742	order	http://holote.vn:8083/image-storage/IMG1733023249079436595.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1384	2024-12-01 03:25:18.368384+00	2024-12-01 03:25:18.368384+00	\N	742	order	/data/user/0/com.example.app_mobile/cache/scaled_d9f3aeab-2873-4eac-b5e3-054c0a4935e06108481559522142353.jpg	admin_confirm_order_paid_image	\N	4	admin
1385	2024-12-01 03:36:14.901319+00	2024-12-01 03:36:14.901319+00	\N	568	log_order	http://holote.vn:8083/image-storage/IMG1733024172468086937.jpeg	log_order_weight_ticket_image_receive	744	180	driver
1195	2024-11-27 07:52:42.592102+00	2024-11-27 07:52:42.592102+00	\N	490	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1224	2024-11-28 03:47:32.265685+00	2024-11-28 03:47:32.265685+00	\N	509	log_order	http://holote.vn:8083/image-storage/IMG1732765650198289340.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1194	2024-11-27 07:52:42.468608+00	2024-11-27 07:52:42.468608+00	\N	490	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1192	2024-11-27 07:52:37.939182+00	2024-11-27 07:52:37.939182+00	\N	490	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1197	2024-11-27 07:54:13.407928+00	2024-11-27 07:54:13.407928+00	\N	491	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1198	2024-11-27 07:54:22.441477+00	2024-11-27 07:54:22.441477+00	\N	491	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1193	2024-11-27 07:52:38.063109+00	2024-11-27 07:52:38.063109+00	\N	490	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1226	2024-11-28 03:48:26.108657+00	2024-11-28 03:48:26.108657+00	\N	539	log_order	http://holote.vn:8083/image-storage/IMG1732765704270843795.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1199	2024-11-27 07:54:22.565587+00	2024-11-27 07:54:22.565587+00	\N	491	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1220	2024-11-28 02:53:50.660723+00	2024-11-28 02:53:50.660723+00	\N	542	log_order	http://holote.vn:8083/image-storage/IMG1732762428469845739.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1222	2024-11-28 03:09:05.555839+00	2024-11-28 03:09:05.555839+00	\N	539	log_order	http://holote.vn:8083/image-storage/IMG1732763343193597849.jpeg	log_order_weight_ticket_image_deliver	\N	\N	\N
1203	2024-11-27 07:54:46.589469+00	2024-11-27 07:54:46.589469+00	\N	492	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1201	2024-11-27 07:54:40.831724+00	2024-11-27 07:54:40.831724+00	\N	492	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1200	2024-11-27 07:54:40.707531+00	2024-11-27 07:54:40.707531+00	\N	492	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	\N	\N	\N
1221	2024-11-28 03:08:26.69977+00	2024-11-28 03:08:26.69977+00	\N	542	log_order	http://holote.vn:8083/image-storage/IMG1732763304753554148.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1223	2024-11-28 03:47:07.270763+00	2024-11-28 03:47:07.270763+00	\N	539	log_order	http://holote.vn:8083/image-storage/IMG1732765625475956751.jpeg	log_order_weight_ticket_image_receive	\N	\N	\N
1202	2024-11-27 07:54:46.466148+00	2024-11-27 07:54:46.466148+00	\N	492	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	\N	\N	\N
1346	2024-11-29 07:11:10.326961+00	2024-11-29 07:11:10.326961+00	\N	565	log_order	http://holote.vn:8083/image-storage/IMG1732864268245443161.jpeg	log_order_weight_ticket_image_receive	732	140	driver
1344	2024-11-29 07:10:06.681234+00	2024-11-29 07:10:06.681234+00	\N	564	log_order	http://holote.vn:8083/image-storage/IMG1732864204535630257.jpeg	log_order_weight_ticket_image_receive	732	139	driver
1376	2024-11-30 21:58:18.125822+00	2024-11-30 21:58:18.125822+00	\N	439	vehicle	http://holote.vn:8083/image-storage/IMG1733003896050937852.jpeg	create_vehicle_image	\N	\N	\N
1377	2024-11-30 22:08:25.777904+00	2024-11-30 22:08:25.777904+00	\N	440	vehicle	http://holote.vn:8083/image-storage/IMG1733004503657847252.jpeg	create_vehicle_image	\N	\N	\N
1378	2024-11-30 23:24:13.402636+00	2024-11-30 23:24:13.402636+00	\N	740	order	http://holote.vn:8083/image-storage/IMG1733009051236393616.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1379	2024-11-30 23:33:10.41988+00	2024-11-30 23:33:10.41988+00	\N	740	order	http://holote.vn:8083/image-storage/IMG1733009588246329111.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1386	2024-12-01 03:36:49.020226+00	2024-12-01 03:36:49.020226+00	\N	568	log_order	http://holote.vn:8083/image-storage/IMG1733024206236360410.jpeg	log_order_weight_ticket_image_deliver	744	180	driver
1387	2024-12-01 03:37:17.321699+00	2024-12-01 03:37:17.321699+00	\N	569	log_order	http://holote.vn:8083/image-storage/IMG1733024234919671240.jpeg	log_order_weight_ticket_image_receive	744	180	driver
1388	2024-12-01 03:37:51.310725+00	2024-12-01 03:37:51.310725+00	\N	569	log_order	http://holote.vn:8083/image-storage/IMG1733024268636656505.jpeg	log_order_weight_ticket_image_deliver	744	180	driver
1389	2024-12-01 03:39:21.878043+00	2024-12-01 03:39:21.878043+00	\N	570	log_order	http://holote.vn:8083/image-storage/IMG1733024359517232533.jpeg	log_order_weight_ticket_image_receive	744	180	driver
1390	2024-12-01 03:40:11.080726+00	2024-12-01 03:40:11.080726+00	\N	570	log_order	http://holote.vn:8083/image-storage/IMG1733024408444415756.jpeg	log_order_weight_ticket_image_deliver	744	180	driver
1391	2024-12-01 03:54:18.39329+00	2024-12-01 03:54:18.39329+00	\N	571	log_order	http://holote.vn:8083/image-storage/IMG1733025256087589845.jpeg	log_order_weight_ticket_image_receive	744	180	driver
1392	2024-12-01 03:54:42.330485+00	2024-12-01 03:54:42.330485+00	\N	571	log_order	http://holote.vn:8083/image-storage/IMG1733025279733149501.jpeg	log_order_weight_ticket_image_deliver	744	180	driver
1393	2024-12-01 04:00:29.42132+00	2024-12-01 04:00:29.42132+00	\N	744	order	http://holote.vn:8083/image-storage/IMG1733025581462313087.jpeg	admin_confirm_order_paid_image	\N	4	admin
1394	2024-12-01 04:39:46.215536+00	2024-12-01 04:39:46.215536+00	\N	572	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	746	163	driver
1395	2024-12-01 04:39:46.333555+00	2024-12-01 04:39:46.333555+00	\N	572	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	746	163	driver
1396	2024-12-01 04:40:17.283847+00	2024-12-01 04:40:17.283847+00	\N	572	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	746	163	driver
1397	2024-12-01 04:40:17.408804+00	2024-12-01 04:40:17.408804+00	\N	572	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	746	163	driver
1398	2024-12-01 04:40:41.681452+00	2024-12-01 04:40:41.681452+00	\N	573	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	746	163	driver
1399	2024-12-01 04:40:41.783451+00	2024-12-01 04:40:41.783451+00	\N	573	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	746	163	driver
1400	2024-12-01 04:40:47.502547+00	2024-12-01 04:40:47.502547+00	\N	573	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	746	163	driver
1401	2024-12-01 04:40:47.60986+00	2024-12-01 04:40:47.60986+00	\N	573	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	746	163	driver
1402	2024-12-01 04:41:54.969238+00	2024-12-01 04:41:54.969238+00	\N	574	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	746	163	driver
1403	2024-12-01 04:41:55.073595+00	2024-12-01 04:41:55.073595+00	\N	574	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	746	163	driver
1404	2024-12-01 04:43:32.842276+00	2024-12-01 04:43:32.842276+00	\N	574	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	746	163	driver
1405	2024-12-01 04:43:32.966882+00	2024-12-01 04:43:32.966882+00	\N	574	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	746	163	driver
1406	2024-12-01 04:46:34.868484+00	2024-12-01 04:46:34.868484+00	\N	575	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	746	163	driver
1407	2024-12-01 04:46:35.06145+00	2024-12-01 04:46:35.06145+00	\N	575	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	746	163	driver
1408	2024-12-01 04:47:23.575023+00	2024-12-01 04:47:23.575023+00	\N	575	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	746	163	driver
1409	2024-12-01 04:47:23.697633+00	2024-12-01 04:47:23.697633+00	\N	575	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	746	163	driver
1410	2024-12-01 04:48:48.117989+00	2024-12-01 04:48:48.117989+00	\N	746	project_order	http://lorna.org	admin_confirm_project_order_paid_image	\N	0	admin
1419	2024-12-01 05:26:26.257201+00	2024-12-01 05:26:26.257201+00	\N	580	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	749	180	driver
1420	2024-12-01 05:26:26.370311+00	2024-12-01 05:26:26.370311+00	\N	580	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	749	180	driver
1429	2024-12-01 05:28:37.214079+00	2024-12-01 05:28:37.214079+00	\N	583	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	749	180	driver
1430	2024-12-01 05:28:37.40148+00	2024-12-01 05:28:37.40148+00	\N	583	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	749	180	driver
1411	2024-12-01 04:55:59.116781+00	2024-12-01 04:55:59.116781+00	\N	576	log_order	http://holote.vn:8083/image-storage/IMG1733028956729854573.jpeg	log_order_weight_ticket_image_receive	748	180	driver
1412	2024-12-01 04:56:18.92753+00	2024-12-01 04:56:18.92753+00	\N	576	log_order	http://holote.vn:8083/image-storage/IMG1733028976271902855.jpeg	log_order_weight_ticket_image_deliver	748	180	driver
1413	2024-12-01 04:56:42.999827+00	2024-12-01 04:56:42.999827+00	\N	577	log_order	http://holote.vn:8083/image-storage/IMG1733029000661058668.jpeg	log_order_weight_ticket_image_receive	748	180	driver
1414	2024-12-01 04:57:02.786882+00	2024-12-01 04:57:02.786882+00	\N	577	log_order	http://holote.vn:8083/image-storage/IMG1733029020145762812.jpeg	log_order_weight_ticket_image_deliver	748	180	driver
1415	2024-12-01 04:57:53.390941+00	2024-12-01 04:57:53.390941+00	\N	578	log_order	http://holote.vn:8083/image-storage/IMG1733029071037429476.jpeg	log_order_weight_ticket_image_receive	748	180	driver
1416	2024-12-01 04:58:31.403934+00	2024-12-01 04:58:31.403934+00	\N	578	log_order	http://holote.vn:8083/image-storage/IMG1733029108758483434.jpeg	log_order_weight_ticket_image_deliver	748	180	driver
1417	2024-12-01 05:00:38.30928+00	2024-12-01 05:00:38.30928+00	\N	579	log_order	http://holote.vn:8083/image-storage/IMG1733029236034505860.jpeg	log_order_weight_ticket_image_receive	748	180	driver
1418	2024-12-01 05:01:14.443782+00	2024-12-01 05:01:14.443782+00	\N	579	log_order	http://holote.vn:8083/image-storage/IMG1733029271830906454.jpeg	log_order_weight_ticket_image_deliver	748	180	driver
1421	2024-12-01 05:26:47.600633+00	2024-12-01 05:26:47.600633+00	\N	580	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	749	180	driver
1422	2024-12-01 05:26:47.72755+00	2024-12-01 05:26:47.72755+00	\N	580	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	749	180	driver
1423	2024-12-01 05:27:03.949873+00	2024-12-01 05:27:03.949873+00	\N	581	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	749	180	driver
1424	2024-12-01 05:27:04.076554+00	2024-12-01 05:27:04.076554+00	\N	581	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	749	180	driver
1425	2024-12-01 05:27:21.029166+00	2024-12-01 05:27:21.029166+00	\N	581	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	749	180	driver
1426	2024-12-01 05:27:21.154955+00	2024-12-01 05:27:21.154955+00	\N	581	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	749	180	driver
1427	2024-12-01 05:27:35.277146+00	2024-12-01 05:27:35.277146+00	\N	582	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	749	180	driver
1428	2024-12-01 05:27:35.402913+00	2024-12-01 05:27:35.402913+00	\N	582	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	749	180	driver
1431	2024-12-01 05:38:53.999002+00	2024-12-01 05:38:53.999002+00	\N	584	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	750	180	driver
1432	2024-12-01 05:38:54.125293+00	2024-12-01 05:38:54.125293+00	\N	584	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	750	180	driver
1433	2024-12-01 05:39:25.999545+00	2024-12-01 05:39:25.999545+00	\N	584	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	750	180	driver
1434	2024-12-01 05:39:26.125725+00	2024-12-01 05:39:26.125725+00	\N	584	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	750	180	driver
1435	2024-12-01 05:39:41.675592+00	2024-12-01 05:39:41.675592+00	\N	585	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	750	180	driver
1436	2024-12-01 05:39:41.802602+00	2024-12-01 05:39:41.802602+00	\N	585	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	750	180	driver
1437	2024-12-01 05:39:45.76459+00	2024-12-01 05:39:45.76459+00	\N	585	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	750	180	driver
1438	2024-12-01 05:39:45.891676+00	2024-12-01 05:39:45.891676+00	\N	585	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	750	180	driver
1439	2024-12-01 05:39:58.154864+00	2024-12-01 05:39:58.154864+00	\N	586	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	750	180	driver
1440	2024-12-01 05:39:58.280848+00	2024-12-01 05:39:58.280848+00	\N	586	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	750	180	driver
1441	2024-12-01 05:42:27.174196+00	2024-12-01 05:42:27.174196+00	\N	587	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	750	180	driver
1442	2024-12-01 05:42:27.301152+00	2024-12-01 05:42:27.301152+00	\N	587	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	750	180	driver
1443	2024-12-01 05:42:32.588041+00	2024-12-01 05:42:32.588041+00	\N	587	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	750	180	driver
1444	2024-12-01 05:42:32.716144+00	2024-12-01 05:42:32.716144+00	\N	587	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	750	180	driver
1445	2024-12-01 05:43:15.404379+00	2024-12-01 05:43:15.404379+00	\N	588	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	750	180	driver
1446	2024-12-01 05:43:15.531347+00	2024-12-01 05:43:15.531347+00	\N	588	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_receive	750	180	driver
1447	2024-12-01 05:43:21.489549+00	2024-12-01 05:43:21.489549+00	\N	588	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	750	180	driver
1448	2024-12-01 05:43:21.618304+00	2024-12-01 05:43:21.618304+00	\N	588	log_order	http://placeimg.com/640/480	log_order_weight_ticket_image_deliver	750	180	driver
1449	2024-12-01 05:43:51.690764+00	2024-12-01 05:43:51.690764+00	\N	750	project_order	http://makenzie.info	admin_confirm_project_order_paid_image	\N	0	admin
1450	2024-12-01 05:55:36.576381+00	2024-12-01 05:55:36.576381+00	\N	589	log_order	http://holote.vn:8083/image-storage/IMG1733032534106781115.jpeg	log_order_weight_ticket_image_receive	751	180	driver
1451	2024-12-01 05:56:09.06723+00	2024-12-01 05:56:09.06723+00	\N	589	log_order	http://holote.vn:8083/image-storage/IMG1733032566374404501.jpeg	log_order_weight_ticket_image_deliver	751	180	driver
1452	2024-12-01 05:57:18.918469+00	2024-12-01 05:57:18.918469+00	\N	590	log_order	http://holote.vn:8083/image-storage/IMG1733032636376792458.jpeg	log_order_weight_ticket_image_receive	751	180	driver
1453	2024-12-01 05:57:41.2746+00	2024-12-01 05:57:41.2746+00	\N	590	log_order	http://holote.vn:8083/image-storage/IMG1733032658441918235.jpeg	log_order_weight_ticket_image_deliver	751	180	driver
1454	2024-12-01 05:58:07.955035+00	2024-12-01 05:58:07.955035+00	\N	591	log_order	http://holote.vn:8083/image-storage/IMG1733032685437599765.jpeg	log_order_weight_ticket_image_receive	751	180	driver
1455	2024-12-01 05:58:43.672802+00	2024-12-01 05:58:43.672802+00	\N	591	log_order	http://holote.vn:8083/image-storage/IMG1733032720767859416.jpeg	log_order_weight_ticket_image_deliver	751	180	driver
1456	2024-12-01 05:59:30.444651+00	2024-12-01 05:59:30.444651+00	\N	592	log_order	http://holote.vn:8083/image-storage/IMG1733032767946508280.jpeg	log_order_weight_ticket_image_receive	751	180	driver
1457	2024-12-01 05:59:53.407635+00	2024-12-01 05:59:53.407635+00	\N	592	log_order	http://holote.vn:8083/image-storage/IMG1733032790662180278.jpeg	log_order_weight_ticket_image_deliver	751	180	driver
1458	2024-12-01 05:39:26.125725+00	2024-12-01 05:39:26.125725+00	\N	584	log_order	http://placeimg.com/640/480	additional_log_order_weight_ticket_image_deliver	750	180	driver
1459	2024-12-01 08:27:54.858223+00	2024-12-01 08:27:54.858223+00	\N	751	project_order	http://holote.vn:8083/image-storage/IMG1733041672954117929.jpeg	admin_confirm_project_order_paid_image	\N	0	admin
1460	2024-12-02 00:43:12.638644+00	2024-12-02 00:43:12.638644+00	\N	745	order	http://holote.vn:8083/image-storage/IMG1733100181278961264.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1461	2024-12-02 00:44:07.56865+00	2024-12-02 00:44:07.56865+00	\N	745	order	http://holote.vn:8083/image-storage/IMG1733100237761107749.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1462	2024-12-02 00:52:50.193364+00	2024-12-02 00:52:50.193364+00	\N	752	order	http://holote.vn:8083/image-storage/IMG1733100767788893387.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1463	2024-12-02 00:53:18.729304+00	2024-12-02 00:53:18.729304+00	\N	752	order	http://holote.vn:8083/image-storage/IMG1733100796324962130.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1464	2024-12-02 00:54:58.269833+00	2024-12-02 00:54:58.269833+00	\N	752	order	http://holote.vn:8083/image-storage/IMG1733100896178208836.jpeg	admin_confirm_order_paid_image	\N	4	admin
1465	2024-12-02 01:09:35.08636+00	2024-12-02 01:09:35.08636+00	\N	593	log_order	http://holote.vn:8083/image-storage/IMG1733101772455515772.jpeg	log_order_weight_ticket_image_receive	755	180	driver
1466	2024-12-02 01:10:11.673888+00	2024-12-02 01:10:11.673888+00	\N	593	log_order	http://holote.vn:8083/image-storage/IMG1733101808728364870.jpeg	log_order_weight_ticket_image_deliver	755	180	driver
1467	2024-12-02 01:21:47.496345+00	2024-12-02 01:21:47.496345+00	\N	594	log_order	http://holote.vn:8083/image-storage/IMG1733102504846177593.jpeg	log_order_weight_ticket_image_receive	755	180	driver
1468	2024-12-02 01:43:08.699272+00	2024-12-02 01:43:08.699272+00	\N	594	log_order	http://holote.vn:8083/image-storage/IMG1733103753209631989.jpeg	additional_log_order_weight_ticket_image_deliver	755	180	driver
1469	2024-12-02 02:03:02.503854+00	2024-12-02 02:03:02.503854+00	\N	594	log_order	http://holote.vn:8083/image-storage/IMG1733104979475098654.jpeg	log_order_weight_ticket_image_deliver	755	180	driver
1470	2024-12-02 02:06:01.138801+00	2024-12-02 02:06:01.138801+00	\N	595	log_order	http://holote.vn:8083/image-storage/IMG1733105158536540038.jpeg	log_order_weight_ticket_image_receive	755	180	driver
1471	2024-12-02 02:07:53.66911+00	2024-12-02 02:07:53.66911+00	\N	595	log_order	http://holote.vn:8083/image-storage/IMG1733105270696227870.jpeg	log_order_weight_ticket_image_deliver	755	180	driver
1472	2024-12-02 02:09:24.00584+00	2024-12-02 02:09:24.00584+00	\N	596	log_order	http://holote.vn:8083/image-storage/IMG1733105361357032002.jpeg	log_order_weight_ticket_image_receive	755	180	driver
1473	2024-12-02 02:09:59.594784+00	2024-12-02 02:09:59.594784+00	\N	596	log_order	http://holote.vn:8083/image-storage/IMG1733105396648089869.jpeg	log_order_weight_ticket_image_deliver	755	180	driver
1474	2024-12-02 02:15:16.63804+00	2024-12-02 02:15:16.63804+00	\N	597	log_order	http://holote.vn:8083/image-storage/IMG1733105714095695013.jpeg	log_order_weight_ticket_image_receive	755	180	driver
1475	2024-12-02 02:17:21.996746+00	2024-12-02 02:17:21.996746+00	\N	597	log_order	http://holote.vn:8083/image-storage/IMG1733105839229848349.jpeg	log_order_weight_ticket_image_deliver	755	180	driver
1476	2024-12-02 02:18:05.50788+00	2024-12-02 02:18:05.50788+00	\N	755	project_order	http://holote.vn:8083/image-storage/IMG1733105883475122042.jpeg	admin_confirm_project_order_paid_image	\N	0	admin
1477	2024-12-02 02:29:30.378761+00	2024-12-02 02:29:30.378761+00	\N	598	log_order	http://holote.vn:8083/image-storage/IMG1733106567809764372.jpeg	log_order_weight_ticket_image_receive	756	180	driver
1478	2024-12-02 02:30:58.456607+00	2024-12-02 02:30:58.456607+00	\N	598	log_order	http://holote.vn:8083/image-storage/IMG1733106655488361571.jpeg	log_order_weight_ticket_image_deliver	756	180	driver
1479	2024-12-02 02:32:14.330935+00	2024-12-02 02:32:14.330935+00	\N	599	log_order	http://holote.vn:8083/image-storage/IMG1733106731708186737.jpeg	log_order_weight_ticket_image_receive	756	180	driver
1480	2024-12-02 02:33:08.680089+00	2024-12-02 02:33:08.680089+00	\N	599	log_order	http://holote.vn:8083/image-storage/IMG1733106786320770447.jpeg	additional_log_order_weight_ticket_image_deliver	756	180	driver
1481	2024-12-02 02:34:57.800421+00	2024-12-02 02:34:57.800421+00	\N	599	log_order	http://holote.vn:8083/image-storage/IMG1733106786320770447.jpeg	additional_log_order_weight_ticket_image_deliver	756	180	driver
1482	2024-12-02 02:35:10.300786+00	2024-12-02 02:35:10.300786+00	\N	599	log_order	http://holote.vn:8083/image-storage/IMG1733106786320770447.jpeg	additional_log_order_weight_ticket_image_deliver	756	180	driver
1483	2024-12-02 02:43:45.886591+00	2024-12-02 02:43:45.886591+00	\N	599	log_order	http://holote.vn:8083/image-storage/IMG1733106786320770447.jpeg	log_order_weight_ticket_image_deliver	756	180	driver
1484	2024-12-02 02:44:11.638354+00	2024-12-02 02:44:11.638354+00	\N	600	log_order	http://holote.vn:8083/image-storage/IMG1733107449044371953.jpeg	log_order_weight_ticket_image_receive	756	180	driver
1485	2024-12-02 02:44:40.115714+00	2024-12-02 02:44:40.115714+00	\N	600	log_order	http://holote.vn:8083/image-storage/IMG1733107477037666438.jpeg	log_order_weight_ticket_image_deliver	756	180	driver
1486	2024-12-02 02:45:09.226609+00	2024-12-02 02:45:09.226609+00	\N	601	log_order	http://holote.vn:8083/image-storage/IMG1733107506600032122.jpeg	log_order_weight_ticket_image_receive	756	180	driver
1487	2024-12-02 02:45:33.095176+00	2024-12-02 02:45:33.095176+00	\N	601	log_order	http://holote.vn:8083/image-storage/IMG1733107530123886882.jpeg	log_order_weight_ticket_image_deliver	756	180	driver
1488	2024-12-02 02:46:24.46173+00	2024-12-02 02:46:24.46173+00	\N	602	log_order	http://holote.vn:8083/image-storage/IMG1733107581723304780.jpeg	log_order_weight_ticket_image_receive	756	180	driver
1489	2024-12-02 02:46:49.572844+00	2024-12-02 02:46:49.572844+00	\N	602	log_order	http://holote.vn:8083/image-storage/IMG1733107606636529085.jpeg	log_order_weight_ticket_image_deliver	756	180	driver
1490	2024-12-02 02:53:15.596431+00	2024-12-02 02:53:15.596431+00	\N	603	log_order	http://holote.vn:8083/image-storage/IMG1733106786320770447.jpeg	additional_log_order_weight_ticket_image_deliver	756	180	driver
1491	2024-12-02 02:54:44.758153+00	2024-12-02 02:54:44.758153+00	\N	603	log_order	http://holote.vn:8083/image-storage/IMG1733108081876109705.jpeg	log_order_weight_ticket_image_deliver	756	180	driver
1492	2024-12-02 03:05:52.864037+00	2024-12-02 03:05:52.864037+00	\N	604	log_order	http://holote.vn:8083/image-storage/IMG1733108750243885227.jpeg	log_order_weight_ticket_image_receive	758	180	driver
1493	2024-12-02 03:06:29.306042+00	2024-12-02 03:06:29.306042+00	\N	604	log_order	http://holote.vn:8083/image-storage/IMG1733108786366505200.jpeg	log_order_weight_ticket_image_deliver	758	180	driver
1494	2024-12-02 03:06:58.044147+00	2024-12-02 03:06:58.044147+00	\N	605	log_order	http://holote.vn:8083/image-storage/IMG1733108815444648701.jpeg	log_order_weight_ticket_image_receive	758	180	driver
1495	2024-12-02 03:07:17.938594+00	2024-12-02 03:07:17.938594+00	\N	605	log_order	http://holote.vn:8083/image-storage/IMG1733108835064168866.jpeg	log_order_weight_ticket_image_deliver	758	180	driver
1496	2024-12-02 03:07:44.668838+00	2024-12-02 03:07:44.668838+00	\N	757	order	http://holote.vn:8083/image-storage/IMG1733108862300932056.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1497	2024-12-02 03:07:52.182363+00	2024-12-02 03:07:52.182363+00	\N	606	log_order	http://holote.vn:8083/image-storage/IMG1733108869595645692.jpeg	log_order_weight_ticket_image_receive	758	180	driver
1498	2024-12-02 03:08:28.490574+00	2024-12-02 03:08:28.490574+00	\N	757	order	http://holote.vn:8083/image-storage/IMG1733108906176719465.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1499	2024-12-02 03:08:33.388421+00	2024-12-02 03:08:33.388421+00	\N	606	log_order	http://holote.vn:8083/image-storage/IMG1733108910505621218.jpeg	log_order_weight_ticket_image_deliver	758	180	driver
1500	2024-12-02 03:13:48.91991+00	2024-12-02 03:13:48.91991+00	\N	757	order	http://holote.vn:8083/image-storage/IMG1733109226734228681.jpeg	admin_confirm_order_paid_image	\N	4	admin
1501	2024-12-02 03:25:09.014738+00	2024-12-02 03:25:09.014738+00	\N	607	log_order	http://holote.vn:8083/image-storage/IMG1733109906430205920.jpeg	log_order_weight_ticket_image_receive	758	180	driver
1502	2024-12-02 03:25:32.374792+00	2024-12-02 03:25:32.374792+00	\N	607	log_order	http://holote.vn:8083/image-storage/IMG1733109929431474002.jpeg	log_order_weight_ticket_image_deliver	758	180	driver
1503	2024-12-02 03:35:54.296925+00	2024-12-02 03:35:54.296925+00	\N	758	project_order	http://holote.vn:8083/image-storage/IMG1733110552244171316.jpeg	admin_confirm_project_order_paid_image	\N	0	admin
1504	2024-12-02 03:38:37.950144+00	2024-12-02 03:38:37.950144+00	\N	608	log_order	http://holote.vn:8083/image-storage/IMG1733110715216876576.jpeg	log_order_weight_ticket_image_receive	759	180	driver
1505	2024-12-02 03:39:01.005592+00	2024-12-02 03:39:01.005592+00	\N	608	log_order	http://holote.vn:8083/image-storage/IMG1733110738061396557.jpeg	log_order_weight_ticket_image_deliver	759	180	driver
1506	2024-12-02 03:39:27.586145+00	2024-12-02 03:39:27.586145+00	\N	609	log_order	http://holote.vn:8083/image-storage/IMG1733110765001166617.jpeg	log_order_weight_ticket_image_receive	759	180	driver
1507	2024-12-02 03:39:43.251288+00	2024-12-02 03:39:43.251288+00	\N	609	log_order	http://holote.vn:8083/image-storage/IMG1733110780807746758.jpeg	additional_log_order_weight_ticket_image_deliver	759	180	driver
1508	2024-12-02 03:41:25.561361+00	2024-12-02 03:41:25.561361+00	\N	609	log_order	http://holote.vn:8083/image-storage/IMG1733110780807746758.jpeg	additional_log_order_weight_ticket_image_deliver	759	180	driver
1509	2024-12-02 03:41:58.682305+00	2024-12-02 03:41:58.682305+00	\N	609	log_order	http://holote.vn:8083/image-storage/IMG1733110916359084293.jpeg	additional_log_order_weight_ticket_image_deliver	759	180	driver
1510	2024-12-02 03:43:07.330213+00	2024-12-02 03:43:07.330213+00	\N	609	log_order	http://holote.vn:8083/image-storage/IMG1733110985003398653.jpeg	additional_log_order_weight_ticket_image_deliver	759	180	driver
1511	2024-12-02 03:43:08.248344+00	2024-12-02 03:43:08.248344+00	\N	760	order	http://holote.vn:8083/image-storage/IMG1733110985797187345.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1512	2024-12-02 03:43:26.953732+00	2024-12-02 03:43:26.953732+00	\N	609	log_order	http://holote.vn:8083/image-storage/IMG1733111004069529503.jpeg	log_order_weight_ticket_image_deliver	759	180	driver
1513	2024-12-02 03:44:01.856203+00	2024-12-02 03:44:01.856203+00	\N	760	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1514	2024-12-02 03:44:34.39331+00	2024-12-02 03:44:34.39331+00	\N	760	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1515	2024-12-02 03:44:34.517039+00	2024-12-02 03:44:34.517039+00	\N	760	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1516	2024-12-02 03:44:35.381064+00	2024-12-02 03:44:35.381064+00	\N	610	log_order	http://holote.vn:8083/image-storage/IMG1733111072734077765.jpeg	log_order_weight_ticket_image_receive	759	180	driver
1517	2024-12-02 03:44:54.58963+00	2024-12-02 03:44:54.58963+00	\N	610	log_order	http://holote.vn:8083/image-storage/IMG1733111091736065382.jpeg	log_order_weight_ticket_image_deliver	759	180	driver
1518	2024-12-02 03:45:01.169997+00	2024-12-02 03:45:01.169997+00	\N	760	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1519	2024-12-02 03:45:01.293728+00	2024-12-02 03:45:01.293728+00	\N	760	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1520	2024-12-02 03:45:25.732285+00	2024-12-02 03:45:25.732285+00	\N	760	order	http://holote.vn:8083/image-storage/IMG1733111123477013901.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1521	2024-12-02 03:48:20.336638+00	2024-12-02 03:48:20.336638+00	\N	761	order	http://holote.vn:8083/image-storage/IMG1733111298025571015.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1522	2024-12-02 03:48:45.024461+00	2024-12-02 03:48:45.024461+00	\N	761	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1523	2024-12-02 03:48:45.148269+00	2024-12-02 03:48:45.148269+00	\N	761	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1524	2024-12-02 03:57:13.539494+00	2024-12-02 03:57:13.539494+00	\N	611	log_order	http://holote.vn:8083/image-storage/IMG1733111830960960850.jpeg	log_order_weight_ticket_image_receive	759	180	driver
1525	2024-12-02 03:57:30.753395+00	2024-12-02 03:57:30.753395+00	\N	611	log_order	http://holote.vn:8083/image-storage/IMG1733111847917612133.jpeg	log_order_weight_ticket_image_deliver	759	180	driver
1526	2024-12-02 03:58:03.447681+00	2024-12-02 03:58:03.447681+00	\N	761	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1527	2024-12-02 03:58:16.02056+00	2024-12-02 03:58:16.02056+00	\N	761	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1528	2024-12-02 04:01:26.449835+00	2024-12-02 04:01:26.449835+00	\N	759	project_order	http://holote.vn:8083/image-storage/IMG1733112084356637022.jpeg	admin_confirm_project_order_paid_image	\N	0	admin
1529	2024-12-02 04:02:02.958866+00	2024-12-02 04:02:02.958866+00	\N	441	vehicle	http://holote.vn:8083/image-storage/IMG1733112120666371081.jpeg	create_vehicle_image	\N	\N	\N
1530	2024-12-02 04:02:41.55628+00	2024-12-02 04:02:41.55628+00	\N	442	vehicle	http://holote.vn:8083/image-storage/IMG1733112159177539062.jpeg	create_vehicle_image	\N	\N	\N
1531	2024-12-02 04:03:37.764001+00	2024-12-02 04:03:37.764001+00	\N	761	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1532	2024-12-02 04:03:37.872168+00	2024-12-02 04:03:37.872168+00	\N	761	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1533	2024-12-02 04:08:10.513404+00	2024-12-02 04:08:10.513404+00	\N	761	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1534	2024-12-02 04:08:10.638616+00	2024-12-02 04:08:10.638616+00	\N	761	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1535	2024-12-02 04:09:23.444408+00	2024-12-02 04:09:23.444408+00	\N	761	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1536	2024-12-02 04:09:23.567875+00	2024-12-02 04:09:23.567875+00	\N	761	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1537	2024-12-02 04:10:45.862441+00	2024-12-02 04:10:45.862441+00	\N	761	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1538	2024-12-02 04:10:45.987085+00	2024-12-02 04:10:45.987085+00	\N	761	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1539	2024-12-02 04:11:57.800166+00	2024-12-02 04:11:57.800166+00	\N	761	order	http://holote.vn:8083/image-storage/IMG1733112715456879670.jpeg	order_weight_ticket_image_deliver	\N	\N	\N
1540	2024-12-02 04:14:43.159461+00	2024-12-02 04:14:43.159461+00	\N	762	order	http://holote.vn:8083/image-storage/IMG1733112880804798608.jpeg	order_weight_ticket_image_receive	\N	\N	\N
1541	2024-12-02 04:15:15.618995+00	2024-12-02 04:15:15.618995+00	\N	762	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1542	2024-12-02 04:15:15.743021+00	2024-12-02 04:15:15.743021+00	\N	762	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1543	2024-12-02 04:17:19.829793+00	2024-12-02 04:17:19.829793+00	\N	762	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1544	2024-12-02 04:17:19.954285+00	2024-12-02 04:17:19.954285+00	\N	762	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1545	2024-12-02 04:20:41.807358+00	2024-12-02 04:20:41.807358+00	\N	763	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1546	2024-12-02 04:21:15.418159+00	2024-12-02 04:21:15.418159+00	\N	763	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1547	2024-12-02 04:21:15.541725+00	2024-12-02 04:21:15.541725+00	\N	763	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1548	2024-12-02 04:21:29.784636+00	2024-12-02 04:21:29.784636+00	\N	763	order	http://placeimg.com/640/480	order_weight_ticket_image_deliver	\N	\N	\N
1549	2024-12-02 04:23:48.318646+00	2024-12-02 04:23:48.318646+00	\N	764	order	http://placeimg.com/640/480	order_weight_ticket_image_receive	\N	\N	\N
1550	2024-12-02 04:24:09.655445+00	2024-12-02 04:24:09.655445+00	\N	764	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1551	2024-12-02 04:24:09.779155+00	2024-12-02 04:24:09.779155+00	\N	764	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1552	2024-12-02 04:26:05.384709+00	2024-12-02 04:26:05.384709+00	\N	764	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1553	2024-12-02 04:26:05.508563+00	2024-12-02 04:26:05.508563+00	\N	764	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1554	2024-12-02 04:26:42.187732+00	2024-12-02 04:26:42.187732+00	\N	764	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
1555	2024-12-02 04:26:42.312363+00	2024-12-02 04:26:42.312363+00	\N	764	order	http://placeimg.com/640/480	additional_order_weight_ticket_image_deliver	\N	163	driver
\.


--
-- Data for Name: operators; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.operators (id, created_at, updated_at, deleted_at, symbol, code) FROM stdin;
1	2024-11-12 09:12:41.057961+00	2024-11-12 09:12:41.057961+00	\N	+	OPERS1
2	2024-11-12 09:12:41.057961+00	2024-11-12 09:12:41.057961+00	\N	-	OPERS2
3	2024-11-12 09:12:41.057961+00	2024-11-12 09:12:41.057961+00	\N	*	OPERS3
4	2024-11-12 09:12:41.057961+00	2024-11-12 09:12:41.057961+00	\N	/	OPERS4
5	2024-11-12 09:12:41.057961+00	2024-11-12 09:12:41.057961+00	\N	(	OPERS5
6	2024-11-12 09:12:41.057961+00	2024-11-12 09:12:41.057961+00	\N	)	OPERS6
\.


--
-- Data for Name: order_customer; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.order_customer (id, created_at, updated_at, deleted_at, pre_order_id, owner_car_id, customer_id, truck_id, name_customer_to, name_customer_from, phone_number_customer_to, phone_number_customer_from, order_type, quantity, kg, price_router, status, time_pick, note, address_to, address_from, list_driver, time_order_delivered, lat_from, time_order_in_transit, time_order_canceled, long_to, time_order_assigned, long_from, time_order_paid, time_order_arrived, lat_to, time_order_init, cancel_person, cancel_person_id, cancel_reason, cancel_status, price_router_vat) FROM stdin;
5	2024-07-15 10:19:28.989599+00	2024-07-15 10:19:28.989599+00	\N	AE3WHV9V5NXP	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721038614219	\N	10.76468125519378	1721038613836	\N	0	\N	0	\N
7	2024-07-15 10:21:12.305213+00	2024-07-15 10:21:12.305213+00	\N	EPZT9LKQBCJ0	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721038872304	\N	10.76468125519378	1721038872304	\N	0	\N	0	\N
8	2024-07-16 04:57:17.834806+00	2024-07-19 07:08:50.144712+00	\N	AEEL7B1FQWK2	5	1	7	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	3	\N	\N	uz	yo	[7, 7]	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721105837833	\N	10.76468125519378	1721105837833	\N	\N	\N	\N	\N
9	2024-07-19 06:26:29.477552+00	2024-07-19 06:26:29.477552+00	\N	W73ZRMESLWHC	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721370389477	\N	10.76468125519378	1721370389477	\N	\N	\N	\N	\N
10	2024-07-19 06:27:57.700902+00	2024-07-19 06:27:57.700902+00	\N	K5Z0V18VNVLP	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721370477699	\N	10.76468125519378	1721370477699	\N	\N	\N	\N	\N
11	2024-07-19 06:29:18.645836+00	2024-07-19 06:29:18.645836+00	\N	2CDWU7WH37IL	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721370558645	\N	10.76468125519378	1721370558645	\N	\N	\N	\N	\N
6	2024-07-15 10:20:38.593326+00	2024-07-15 10:20:38.593326+00	\N	OOXCQB1G0PH7	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721038838591	\N	10.76468125519378	1721038838591	\N	0	\N	0	\N
12	2024-07-19 06:30:27.780707+00	2024-07-19 06:30:27.780707+00	\N	W422FRANEYO2	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721370627779	\N	10.76468125519378	1721370627779	\N	\N	\N	\N	\N
13	2024-07-19 06:35:11.499136+00	2024-07-19 06:35:11.499136+00	\N	3265DIGFMANB	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721370911499	\N	10.76468125519378	1721370911499	\N	\N	\N	\N	\N
14	2024-07-19 06:35:42.064686+00	2024-07-19 06:35:42.064686+00	\N	NO0UUF3YF1UR	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721370942064	\N	10.76468125519378	1721370942064	\N	\N	\N	\N	\N
15	2024-07-19 06:35:54.650787+00	2024-07-19 06:35:54.650787+00	\N	RUD6VRFI4J91	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721370954649	\N	10.76468125519378	1721370954649	\N	\N	\N	\N	\N
16	2024-07-19 06:37:30.546645+00	2024-07-19 06:37:30.546645+00	\N	SP0V8JIEIUO7	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721371050546	\N	10.76468125519378	1721371050546	\N	\N	\N	\N	\N
17	2024-07-19 06:39:33.485189+00	2024-07-19 06:39:33.485189+00	\N	Z1MFYBC3ABZX	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721371173484	\N	10.76468125519378	1721371173484	\N	\N	\N	\N	\N
18	2024-07-19 06:40:14.248003+00	2024-07-19 06:40:14.248003+00	\N	DFSD9WGJV4I2	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721371214247	\N	10.76468125519378	1721371214247	\N	\N	\N	\N	\N
19	2024-07-19 06:40:41.446714+00	2024-07-19 06:40:41.446714+00	\N	INCZKNV6W9BK	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721371241446	\N	10.76468125519378	1721371241446	\N	\N	\N	\N	\N
20	2024-07-19 06:44:04.008822+00	2024-07-19 06:49:26.833266+00	\N	P3SPPK9TYO11	5	1	7	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721371444008	\N	10.76468125519378	1721371444008	\N	\N	\N	\N	\N
4	2024-07-15 10:16:20.501495+00	2024-07-15 10:16:20.501495+00	\N	E5VQYSLHRJB4	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	uz	yo	\N	\N	11.323972751440522	\N	\N	106.7714826630618	\N	108.80989381330433	1721038575980	\N	10.76468125519378	1721038575980	\N	0	\N	0	\N
3	2024-05-02 09:15:37.97492+00	2024-05-17 10:25:49.849392+00	\N	42a2c708-18b3-11ef-b938-00ff4e3cbed7	1	6	\N	adminto	adminfrom	022928922to	022928922from	bụi tro	1	2000	50000000	2	1712308366682	\N	94/2 Quận 3	24/5 Thanh Mỹ Hai	\N	\N	10.770035363302792	1715157592275	\N	106.69617982416402	1715157581083	106.76846395559477	1715747184478	\N	10.774838165566814	1715157552170	\N	\N	\N	\N	\N
1	2024-05-02 09:15:37.97492+00	2024-05-02 09:15:37.97492+00	\N	235d62f6-0863-11ef-b7c1-00ff4e3cbed7	1	6	1	adminto	adminfrom	022928922to	022928922from	bụi tro	1	2000	50000000	4	1712308366682	\N	94/2 Quận 3	24/5 Thanh Mỹ Hai	[1, 2]	\N	10.770035363302792	1715157592275	\N	106.69617982416402	1715157581083	106.76846395559477	1715157574116	\N	10.774838165566814	1715157552170	\N	\N	\N	\N	\N
2	2024-05-02 09:15:37.97492+00	2024-05-17 10:25:49.849392+00	\N	a9513d8c-fe03-11ee-89bb-00ff4e3cbed7	1	6	1	adminto	adminfrom	022928922to	022928922from	bụi tro	1	2000	50000000	2	1712308366682	\N	94/2 Quận 3	24/5 Thanh Mỹ Hai	[1, 2]	\N	10.770035363302792	1715157592275	\N	106.69617982416402	1715157581083	106.76846395559477	1715747184478	\N	10.774838165566814	1715157552170	customer	6	cancel_reason_customer	8	\N
21	2024-07-29 09:09:52.821048+00	2024-07-29 09:09:52.821048+00	\N	7E7UGNLH455Q	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	\N	is	yo	\N	\N	11.323972751440522	\N	\N	106.76875251982699	\N	108.80989381330433	1722244192820	\N	10.771029175797922	1722244192820	\N	\N	\N	\N	\N
22	2024-07-29 09:17:52.891103+00	2024-07-29 09:17:52.891103+00	\N	KHIKXF2ZU51G	5	1	\N	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	2	\N	Dynamic	is	yo	\N	\N	11.323972751440522	\N	\N	106.76875251982699	\N	108.80989381330433	1722244672890	\N	10.771029175797922	1722244672890	\N	\N	\N	\N	\N
23	2024-07-29 09:22:39.742395+00	2024-07-29 10:10:01.094805+00	\N	1IGZQVNH3LZZ	5	1	7	Grant Littel	Hoa Kien Nhan	380-320-9437	02877703388	ximang	1	1000	739398.676900	3	\N	Principal	is	yo	[7]	\N	11.323972751440522	\N	\N	106.76875251982699	1715157581083	108.80989381330433	1722244959743	\N	10.771029175797922	1722244959743	\N	\N	\N	\N	\N
\.


--
-- Data for Name: orders; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.orders (id, created_at, updated_at, deleted_at, order_name, order_code, customer_id, customer_name, route_id, route_pricing, driver_pricing, address_id_from, contact_name_from, address_phone_number_from, province_from, district_from, ward_from, detail_address_from, lat_from, long_from, address_id_to, contact_name_to, address_phone_number_to, province_to, district_to, ward_to, detail_address_to, lat_to, long_to, quantity, status, description, extra_fee, vat, vat_percent, vat_fee, order_pricing, product_id, product_name, product_price, total_product_price, company_name, tax_code, driver_id, name_driver, vehicle_id, vehicle_plate, additional_plate, formular, order_type, project_process, transport_fee, product_unit, order_distance, real_quantity) FROM stdin;
200	2024-11-18 07:30:49.553371+00	2024-11-18 07:30:49.553371+00	\N	ab	ZGQUATS1L6I3	1	Mrs. Sara Abbott	1	1000000.00	500000.00	1	Dr. Sonja Christiansen	664-503-7747	79	769	26812	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	4	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	100.00	1	\N	\N	t	0.00	0.00	1510000.00	4	nhựa dẻo	100.00	10000.00			\N	\N	\N	\N	\N	f	2	0.00	1500000.00		\N	\N
199	2024-11-18 07:29:04.777942+00	2024-11-18 07:29:04.777942+00	\N	ab	PJYJS022UQAV	1	Mrs. Sara Abbott	1	1000000.00	500000.00	1	Dr. Sonja Christiansen	664-503-7747	79	769	26812	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	4	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	100.00	1	\N	\N	t	0.00	0.00	1508056.00	4	nhựa dẻo	80.56	8056.00			\N	\N	\N	\N	\N	f	2	0.00	1500000.00		\N	\N
303	2024-11-18 13:41:37.376969+00	2024-11-18 13:41:37.376969+00	\N	ab	TMRF0YYOUWVA	1	Mrs. Sara Abbott	1	1000000.00	500000.00	1	Dr. Sonja Christiansen	664-503-7747	79	769	26812	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	4	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	1111.00	1	\N	\N	t	0.00	0.00	2611000.00	4	nhựa dẻo	1000.00	1111000.00	null	null	\N	\N	\N	\N	\N	f	2	0.00	1500000.00		\N	\N
305	2024-11-18 13:43:02.325926+00	2024-11-18 13:43:02.325926+00	\N	ab	53PMDX6OYQ6Q	1	Mrs. Sara Abbott	1	1000000.00	500000.00	1	Dr. Sonja Christiansen	664-503-7747	79	769	26812	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	4	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	1111.00	1	\N	\N	t	8.00	88880.00	2699880.00	4	nhựa dẻo	1000.00	1111000.00	a	b	\N	\N	\N	\N	\N	f	2	0.00	1500000.00		\N	\N
159	2024-11-18 06:11:30.101458+00	2024-11-18 06:11:30.101458+00	\N	\N	UYF76CUWJKG3	1	ab	1	20000.00	30000.00	85	gv	08888888	01	002	00040	8888	66.1809	21.9767	22	ab	12121212	01	001	00001	ab	13.8127	-7.1436	10.00	11		90000.00	t	0.10	12000.00	120000.00	1	tiêu dùng	1000.00	10000.00	12345	ab	\N	\N	\N	\N	\N	f	1	\N	20000.00	tấn	4929535.10	\N
157	2024-11-18 06:05:33.275701+00	2024-11-18 06:05:33.275701+00	\N	\N	V9AMXRA13IHD	1	ab	1	20000.00	30000.00	85	gv	08888888	01	002	00040	8888	66.1809	21.9767	22	ab	12121212	01	001	00001	ab	13.8127	-7.1436	100.00	11		1000.00	t	0.10	13310.00	133100.00	1	tiêu dùng	1000.00	100000.00	12345	ab	\N	\N	\N	\N	\N	f	1	\N	20000.00	tấn	4929535.10	\N
163	2024-11-18 06:15:52.777182+00	2024-11-18 06:15:52.777182+00	\N	\N	B4AK2T0W7042	1	ab	1	20000.00	30000.00	85	gv	08888888	01	002	00040	8888	66.1809	21.9767	22	ab	12121212	01	001	00001	ab	13.8127	-7.1436	10.00	12		1000.00	t	0.10	22100.00	221000.00	6	cát 2	20000.00	200000.00	12345	ab	\N	\N	\N	\N	\N	f	1	\N	20000.00	khối	4929535.10	\N
161	2024-11-18 06:13:31.695804+00	2024-11-18 07:33:26.64629+00	\N	\N	MI5SZSBSTJ1E	1	ab	1	20000.00	30000.00	85	gv	08888888	01	002	00040	8888	66.1809	21.9767	22	ab	12121212	01	001	00001	ab	13.8127	-7.1436	12.00	11		1000.00	t	0.10	26100.00	261000.00	6	cát 2	20000.00	240000.00	12345	ab	9	good.asd	9	49A-78541	49A-48699	f	1	\N	20000.00	khối	4929535.10	\N
158	2024-11-18 06:09:03.305675+00	2024-11-18 06:09:03.305675+00	\N	\N	J0KUCR0BR4HR	1	ab	1	20000.00	30000.00	85	gv	08888888	01	002	00040	8888	66.1809	21.9767	22	ab	12121212	01	001	00001	ab	13.8127	-7.1436	100.00	11		1000.00	t	0.10	12100.00	121000.00	1	tiêu dùng	1000.00	100000.00	12345	ab	\N	\N	\N	\N	\N	f	1	\N	20000.00	tấn	4929535.10	\N
162	2024-11-18 06:14:54.446724+00	2024-11-18 06:14:54.446724+00	\N	\N	EC5KPHKSKKGI	1	ab	1	20000.00	30000.00	85	gv	08888888	01	002	00040	8888	66.1809	21.9767	22	ab	12121212	01	001	00001	ab	13.8127	-7.1436	11.00	12		11122.00	t	0.10	25112.00	251122.00	6	cát 2	20000.00	220000.00	12345	ab	\N	\N	\N	\N	\N	f	1	\N	20000.00	khối	4929535.10	\N
693	2024-11-25 09:23:10.880865+00	2024-11-26 07:47:35.72466+00	\N	\N	VKAOKSYEUF2T	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	10000.00	11		1000.00	f	\N	0.00	411000.00	174	tro	40000.00	400000.00	hkn	6858856	163	nh22	423	60h3489	\N	f	1	\N	10000.00	tấn	89827.80	1000.00
715	2024-11-28 04:01:04.922515+00	2024-11-28 04:03:11.937519+00	\N	khách hàng mua tro	N9H991UIZ8WB	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	4	\N	\N	f	0.00	0.00	120000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	80.00	10000.00	tấn	89827.80	80.00
731	2024-11-29 06:50:37.358407+00	2024-11-29 07:02:07.022835+00	\N	khách hàng mua tro	F2B3POZG5UJ1	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	11	\N	\N	f	0.00	0.00	140000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	100.00	10000.00	tấn	89827.80	100.00
160	2024-11-18 06:12:49.679849+00	2024-11-18 06:12:49.679849+00	\N	\N	2PL6AT5ZL7RQ	1	ab	1	20000.00	30000.00	85	gv	08888888	01	002	00040	8888	66.1809	21.9767	22	ab	12121212	01	001	00001	ab	13.8127	-7.1436	12.00	11		10000.00	t	0.10	0.00	42000.00	1	tiêu dùng	1000.00	12000.00	12345	ab	\N	\N	\N	\N	\N	f	1	\N	20000.00	tấn	4929535.10	\N
201	2024-11-18 07:31:51.208149+00	2024-11-18 07:31:51.208149+00	\N	ab	O1B7ZMQ10IYG	1	Mrs. Sara Abbott	1	1000000.00	500000.00	1	Dr. Sonja Christiansen	664-503-7747	79	769	26812	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	4	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	100.00	1	\N	\N	t	0.00	0.00	1510000.00	4	nhựa dẻo	100.00	10000.00	null	null	\N	\N	\N	\N	\N	f	2	50.00	1500000.00		\N	\N
732	2024-11-29 07:08:56.113924+00	2024-11-29 07:14:23.898594+00	\N	khách hàng mua tro	HRNH5G6XNRSH	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	11	\N	\N	f	0.00	0.00	140000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	100.00	10000.00	tấn	89827.80	100.00
169	2024-11-18 07:25:22.038183+00	2024-11-18 07:25:22.038183+00	\N	Gutmann, Emmerich and Prosacco	0GSQDZ6N7AY9	1	Mrs. Sara Abbott	1	1000000.00	500000.00	1	Dr. Sonja Christiansen	664-503-7747	79	769	26812	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	4	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	100.00	1	\N	\N	t	0.00	0.00	1508056.00	4	nhựa dẻo	80.56	8056.00			\N	\N	\N	\N	\N	f	2	0.00	1500000.00		\N	\N
170	2024-11-18 07:25:36.615664+00	2024-11-18 07:25:36.615664+00	\N	ab	CD3O1KQSG8YJ	1	Mrs. Sara Abbott	1	1000000.00	500000.00	1	Dr. Sonja Christiansen	664-503-7747	79	769	26812	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	4	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	100.00	1	\N	\N	t	0.00	0.00	1508056.00	4	nhựa dẻo	80.56	8056.00			\N	\N	\N	\N	\N	f	2	0.00	1500000.00		\N	\N
167	2024-11-18 07:23:22.727164+00	2024-11-18 07:23:22.727164+00	\N	Gutmann, Emmerich and Prosacco	BWN8A5UAGSN1	1	Mrs. Sara Abbott	1	1000000.00	500000.00	1	Dr. Sonja Christiansen	664-503-7747	79	769	26812	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	4	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	1000.00	1	\N	\N	t	0.00	0.00	1580560.00	4	nhựa dẻo	80.56	80560.00			\N	\N	\N	\N	\N	f	2	0.00	1500000.00		\N	\N
306	2024-11-18 13:44:52.469621+00	2024-11-18 14:45:22.737593+00	\N	ab	0Z9C04V5QFOW	1	Mrs. Sara Abbott	\N	70148667.26	0.00	1	Joshua Boyer	481-637-4467	79	769	26794	76/4, 76/4 QL1A, Linh Xuân, Thủ Đức, Hồ Chí Minh, Việt Nam	10.882023811191013	106.77507815208371	1	Joshua Boyer	481-637-4467	79	769	26794	76/4, 76/4 QL1A, Linh Xuân, Thủ Đức, Hồ Chí Minh, Việt Nam	10.882023811191013	106.77507815208371	1111.00	3	\N	\N	t	8.00	88880.00	71348547.26	4	nhựa dẻo	1000.00	1111000.00	a	b	\N	\N	\N	\N	\N	t	2	0.00	0.00		\N	\N
234	2024-11-18 07:32:50.390418+00	2024-11-18 22:05:41.627204+00	\N	ab	VZ44HQE69ZTF	1	Mrs. Sara Abbott	1	1000000.00	500000.00	1	Dr. Sonja Christiansen	664-503-7747	79	769	26812	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	4	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	100.00	3	\N	\N	t	0.00	0.00	1600000.00	4	nhựa dẻo	1000.00	100000.00	null	null	\N	\N	\N	\N	\N	f	2	0.00	1500000.00		\N	\N
308	2024-11-18 14:44:03.711416+00	2024-11-18 22:05:41.678086+00	\N	ab	32IYMQU0GJP4	7	ab	10	20000.00	30000.00	85	gv	08888888	01	002	00040	8888	66.1809	21.9767	22	ab	12121212	01	001	00001	ab	13.8127	-7.1436	111.00	3	\N	\N	t	0.00	0.00	161000.00	6	cát 2	1000.00	111000.00	12345	ab	\N	\N	\N	\N	\N	f	2	0.00	50000.00		\N	\N
310	2024-11-19 06:59:32.090649+00	2024-11-19 06:59:32.090649+00	\N	Cummerata LLC	50ZU4XUI625T	1	Mrs. Sara Abbott	3	590000.00	250000.00	6	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	18	Stella Heathcote MD	922-319-0321	79	769	26800	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	8800.00	1	\N	\N	t	8.00	4224.00	897024.00	3	tro bay	6.00	52800.00	Zboncak, Dibbert and Runolfsson	32200312	\N	\N	\N	\N	\N	f	2	0.00	840000.00		\N	\N
165	2024-11-18 06:17:45.046442+00	2024-11-18 08:06:21.981081+00	\N	\N	8IIME4JLJ32Y	1	ab	1	20000.00	30000.00	85	gv	08888888	01	002	00040	8888	66.1809	21.9767	22	ab	12121212	01	001	00001	ab	13.8127	-7.1436	111.00	12		12122.00	t	\N	225212.00	2252122.00	6	cát 2	20000.00	2220000.00	12345	ab	4	Mallie63	4	50H-17020	50H-27020	f	1	\N	20000.00	khối	4929535.10	\N
164	2024-11-18 06:16:38.027742+00	2024-11-18 06:16:38.027742+00	\N	\N	FEH1DQ3VB9QS	1	ab	1	20000.00	30000.00	85	gv	08888888	01	002	00040	8888	66.1809	21.9767	22	ab	12121212	01	001	00001	ab	13.8127	-7.1436	111.00	12		12222.00	t	0.10	247744.00	2477444.20	6	cát 2	20000.00	2220000.00	12345	ab	\N	\N	\N	\N	\N	f	1	\N	20000.00	khối	4929535.10	\N
168	2024-11-18 07:23:46.414412+00	2024-11-18 07:23:46.414412+00	\N	Gutmann, Emmerich and Prosacco	17E8X6MXX93Q	1	Mrs. Sara Abbott	1	1000000.00	500000.00	1	Dr. Sonja Christiansen	664-503-7747	79	769	26812	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	4	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	1000.00	1	\N	\N	t	0.00	0.00	1580560.00	4	nhựa dẻo	80.56	80560.00			\N	\N	\N	\N	\N	f	2	0.00	1500000.00		\N	\N
702	2024-11-26 07:50:50.007879+00	2024-11-27 04:15:02.585315+00	\N	khách mua bún đậu	8NLBBKHPZRMX	898	khách mua bún đậu	\N	0.00	861631.68	659	khánh vũ	0968568685	06	062	01945	jdndbd	11.02507740955514	106.7376653832702	660	hkn	0896836856	79	769	27100	quán bún đậu	10.323660175589573	107.11438126186424	100.00	11	\N	\N	f	0.00	0.00	2684895.04	179	bún đậu mắm tôm	1000.00	100000.00	hkn	076787676484648	\N	\N	\N	\N	\N	t	2	100.00	4659366.34	phần	113082.00	100.00
314	2024-11-19 07:42:23.744904+00	2024-11-22 03:52:30.476991+00	\N	\N	LWYCH6RS6RO2	7	ab	46	12010.00	3360000.00	251	a Linh	0987654342	01	001	00006	2 ba trung	66.1809	21.9767	85	gv	08888888	01	002	00040	8888	66.1809	21.9767	11.00	5		111111.00	t	0.10	122312.10	1345433.10	1	tiêu dùng	100000.00	1100000.00	12345	ab	8	good.qwe	8	49A-35520	49A-35722	f	1	\N	12010.00	tấn	0.00	0.00
313	2024-11-19 07:31:32.097311+00	2024-11-27 04:27:02.615869+00	\N	\N	Z6R52I2VJ0Q0	640	Bao AE	\N	\N	\N	454	Bao A	098765463	02	027	00778	34 an lac	10.597808625303523	106.51728802735788	455	Bao B	0984736251	02	027	00778	Binh tan 456	10.257381823872283	106.88753744246766	11.00	3		11111.00	t	0.10	9204314.67	101247461.41	20	tiêu dùng	8000000.00	88000000.00	hknko	19389183813	60	le nha han	264	50b56784	50H-27022	t	1	\N	4032035.74	cái	50923.90	\N
317	2024-11-19 07:58:40.413597+00	2024-11-19 07:58:40.413597+00	\N	\N	74WW18194DXF	7	ab	46	12010.00	3360000.00	251	a Linh	0987654342	01	001	00006	2 ba trung	66.1809	21.9767	85	gv	08888888	01	002	00040	8888	66.1809	21.9767	11.00	1		11111.00	t	\N	0.00	30000.00	1	tiêu dùng	100000.00	1100000.00	12345	ab	\N	\N	\N	\N	\N	t	1	\N	\N	tấn	0.00	\N
716	2024-11-28 05:58:28.423768+00	2024-11-28 06:12:54.897727+00	\N	KH 100	C8HQO5C7QI89	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	100.00	11	\N	\N	f	0.00	0.00	2125000.00	178	túi rác	1000.00	100000.00	hkn	868589	\N	\N	\N	\N	\N	f	2	101.00	25000.00	túi	136971.10	118.00
166	2024-11-18 07:22:37.625688+00	2024-11-18 13:27:30.618453+00	\N	Gutmann, Emmerich and Prosacco	4O7H5UAF53FQ	1	Mrs. Sara Abbott	1	1000000.00	500000.00	1	Dr. Sonja Christiansen	664-503-7747	79	769	26812	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	4	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	1000.00	3	\N	\N	t	0.00	0.00	1580560.00	4	nhựa dẻo	80.56	80560.00			\N	\N	\N	\N	\N	f	2	0.00	1500000.00		\N	\N
318	2024-11-19 08:03:31.960058+00	2024-11-19 08:03:31.960058+00	\N	\N	VZKW38HGSZSF	739	hân lê	55	5000.00	20000.00	461	han le	0346249553	79	769	26818	54 đường số 2	10.82124242881269	106.4844112161959	462	han han	0346249532	62	617	23416	nguyễn bỉnh khiêm	10.548956207761467	106.75198987759788	200.00	1		100000.00	t	0.10	40010500.00	440115500.00	124	dầu	2000000.00	400000000.00	hkn	45673186835	\N	\N	\N	\N	\N	f	1	\N	5000.00	lít	61526.50	\N
703	2024-11-26 08:06:21.556928+00	2024-11-26 08:06:21.556928+00	\N	\N	G30Z8CXMGQ4D	760	linh siêu nhân	60	1000.00	20000.00	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	10.00	1		1000.00	f	\N	\N	102000.00	139	rác bịch	10000.00	100000.00	hkn	98899	\N	\N	\N	\N	\N	f	1	\N	1000.00	túi	65524.40	\N
320	2024-11-19 08:30:43.967131+00	2024-11-19 08:31:48.580057+00	\N	\N	YCN8750D6QNV	740	hân lê 2	\N	\N	\N	464	dt	0897643251	02	024	00688	nsnsjsj	10.774371235468008	106.86845762301319	463	han le	0834692563	01	002	00037	13 dươngd 100	10.756284421745871	106.85798460130704	1000.00	3		1000.00	t	0.10	200393907.78	2204332985.61	126	dầu	2000000.00	2000000000.00	hkn	6468989	16	Francisco7	16	50H-17029	50H-27029	t	1	\N	3938077.83	lít	47504.50	\N
704	2024-11-26 08:09:17.910446+00	2024-11-27 20:11:37.919767+00	\N	\N	6OXKMLRH5ZAS	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	10.00	5		1000.00	f	\N	\N	1026000.00	178	túi rác	100000.00	1000000.00	hkn	868589	57	bao moi	259	50H-12564	\N	f	1	\N	25000.00	túi	136971.10	10.00
332	2024-11-20 02:55:47.10468+00	2024-11-20 02:55:47.10468+00	\N	Bao AE	JZMGE6GXM1M1	640	Bao AE	54	50000.00	20000.00	454	Bao A	098765463	02	027	00778	34 an lac	10.597808625303523	106.51728802735788	455	Bao B	0984736251	02	027	00778	Binh tan 456	10.257381823872283	106.88753744246766	1.00	1	\N	\N	t	10.00	0.00	71100.00	58	tro bay 6	1000.00	1000.00	hknko	19389183813	\N	\N	\N	\N	\N	f	2	0.00	70000.00	tấn	\N	\N
327	2024-11-19 09:00:23.777525+00	2024-11-19 09:01:02.450457+00	\N	hân lê 2	3OQWUCMXZ0C6	740	hân lê 2	\N	3938077.83	370535.10	464	dt	0897643251	02	024	00688	nsnsjsj	10.774371235468008	106.86845762301319	463	han le	0834692563	01	002	00037	13 dươngd 100	10.756284421745871	106.85798460130704	1.00	3	\N	\N	t	0.00	0.00	4309612.93	126	dầu	1000.00	1000.00	hkn	6468989	\N	\N	\N	\N	\N	t	2	0.00	0.00		\N	\N
328	2024-11-19 09:09:12.698394+00	2024-11-19 09:10:03.141114+00	\N	hân lê 2	IZ4GXQN9GBP3	740	hân lê 2	\N	3938077.83	370535.10	464	dt	0897643251	02	024	00688	nsnsjsj	10.774371235468008	106.86845762301319	463	han le	0834692563	01	002	00037	13 dươngd 100	10.756284421745871	106.85798460130704	1.00	3	\N	\N	t	0.00	0.00	4309612.93	126	dầu	1000.00	1000.00	hkn	6468989	\N	\N	\N	\N	\N	t	2	0.00	0.00		\N	\N
718	2024-11-28 06:22:20.420325+00	2024-11-28 06:26:14.981283+00	\N	\N	OZ1LM3LZF2AC	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	10.00	11		1000.00	f	\N	\N	1026000.00	178	túi rác	100000.00	1000000.00	hkn	868589	57	bao moi	259	50H-12564	\N	f	1	\N	25000.00	túi	136971.10	10.00
338	2024-11-20 07:23:54.763786+00	2024-11-20 07:23:54.763786+00	\N	hân nhã 100	JU5JGUXRG8G1	758	hân nhã 100	\N	0.00	0.00	473	han	0765382563	34	343	13093	jsjs	10.530149811745902	106.57360725930458	474	hân	06438683965	10	084	02809	znxn	10.518993973654263	107.00131376552662	100.00	1	\N	\N	f	0.00	0.00	100000.00	137	sắt vụn 2	1000.00	100000.00	snsj	46468686	\N	\N	\N	\N	\N	t	2	0.00	0.00	kí	\N	\N
333	2024-11-20 06:19:45.633119+00	2024-11-20 06:21:36.191289+00	\N	nha han 1	2FJLZSAG3KAT	752	nha han 1	57	200000.00	100000.00	467	nha han 1	0987654567	01	001	0001	haw	-60.9655	169.2644	470	han le	0346249582	01	002	00040	ngõ 55	10.334803162783043	106.26370159844573	2000.00	3	\N	\N	t	10.00	200000.00	2500000.00	3	tro bay	1000.00	2000000.00	hkn	3436453	\N	\N	\N	\N	\N	f	2	0.00	200000.00	tấn	\N	\N
334	2024-11-20 06:33:28.378684+00	2024-11-20 06:33:49.559107+00	\N	hân lê 2	ODPDE32OPR1E	740	hân lê 2	56	20000.00	1000.00	463	han le	0834692563	01	002	00037	13 dươngd 100	10.756284421745871	106.85798460130704	464	dt	0897643251	02	024	00688	nsnsjsj	10.774371235468008	106.86845762301319	100.00	3	\N	\N	t	10.00	10000.00	131000.00	126	dầu	1000.00	100000.00	hkn	6468989	\N	\N	\N	\N	\N	f	2	0.00	20000.00	lít	\N	\N
331	2024-11-20 02:49:48.406908+00	2024-11-20 09:35:29.749506+00	\N	Bao AE	Y1373XLYUWZ7	640	Bao AE	54	50000.00	20000.00	454	Bao A	098765463	02	027	00778	34 an lac	10.597808625303523	106.51728802735788	455	Bao B	0984736251	02	027	00778	Binh tan 456	10.257381823872283	106.88753744246766	1.00	3	\N	\N	t	10.00	100.00	71100.00	20	tiêu dùng	1000.00	1000.00	hknko	19389183813	\N	\N	\N	\N	\N	f	2	0.00	50000.00	cái	\N	\N
335	2024-11-20 06:36:04.465193+00	2024-11-20 06:37:02.941008+00	\N	hân lê 2	OQ4UGPKHMWC7	740	hân lê 2	56	20000.00	1000.00	463	han le	0834692563	01	002	00037	13 dươngd 100	10.756284421745871	106.85798460130704	464	dt	0897643251	02	024	00688	nsnsjsj	10.774371235468008	106.86845762301319	100.00	3	\N	\N	t	10.00	10000.00	131000.00	126	dầu	1000.00	100000.00	hkn	6468989	\N	\N	\N	\N	\N	f	2	0.00	20000.00	lít	\N	\N
717	2024-11-28 06:11:35.450789+00	2024-11-28 06:40:03.899849+00	\N	khách hàng mua tro	J3800GOL2DMJ	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	11	\N	\N	f	0.00	0.00	140000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	100.00	10000.00	tấn	89827.80	100.00
734	2024-11-29 07:28:24.234921+00	2024-11-29 07:54:35.353044+00	\N	\N	ACTHN42T4XJR	895	khách hàng mua tro	\N	\N	\N	652	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	654	hkn2	09683953683	64	623	23617	55 hai bà trưng	10.903530872106048	106.5675667739202	50.00	11		1000.00	f	\N	\N	5728381.90	174	tro	40000.00	2000000.00	hkn	6858856	139	nh8	414	40h5794	\N	t	1	\N	3727381.90	tấn	67540.90	50.00
733	2024-11-29 07:24:46.874295+00	2024-11-29 07:35:28.811991+00	\N	\N	PIPTY91OPDTQ	895	khách hàng mua tro	\N	\N	\N	652	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	652	hkn2	09683953683	64	623	23617	55 hai bà trưng	10.903530872106048	106.5675667739202	40.00	1		1000.00	t	\N	\N	\N	174	tro	80000.00	3200000.00	hkn	6858856	\N	\N	\N	\N	\N	t	1	\N	10000.00	tấn	67540.90	\N
336	2024-11-20 06:39:35.12891+00	2024-11-20 06:40:16.967002+00	\N	hân lê 2	16S2YG57LTED	740	hân lê 2	\N	0.00	386867.52	463	han le	0834692563	01	002	00037	13 dươngd 100	10.756284421745871	106.85798460130704	464	dt	0897643251	02	024	00688	nsnsjsj	10.774371235468008	106.86845762301319	1000.00	3	\N	\N	f	0.00	0.00	5165146.16	126	dầu	1000.00	1000000.00	hkn	6468989	\N	\N	\N	\N	\N	t	2	0.00	3778278.64	lít	\N	\N
388	2024-11-20 09:49:10.392197+00	2024-11-20 09:49:23.371805+00	\N	linh siêu nhân	WXMMWZGUSKS1	760	linh siêu nhân	\N	0.00	511491.24	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	1.00	3	\N	\N	f	0.00	0.00	5241700.94	139	rác bịch	1000.00	1000.00	hkn	98899	\N	\N	\N	\N	\N	t	2	0.00	4729209.70	túi	\N	\N
315	2024-11-19 07:43:11.309222+00	2024-11-21 04:53:36.138653+00	\N	\N	3W7JLOQIFOUF	7	ab	\N	\N	\N	251	a Linh	0987654342	01	001	00006	2 ba trung	66.1809	21.9767	85	gv	08888888	01	002	00040	8888	66.1809	21.9767	114.00	3		1111.00	t	0.10	11606777.92	127674557.13	1	tiêu dùng	100000.00	11400000.00	12345	ab	14	Paolo.Hessel	14	50H-17025	50H-27025	t	1	\N	104666668.21	tấn	0.00	\N
458	2024-11-21 06:22:10.013282+00	2024-11-21 07:09:30.712007+00	\N	\N	06OEPO5GNCJH	760	linh siêu nhân	60	1000.00	20000.00	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	50.00	5		50.00	t	0.10	548284.50	6031129.53	139	rác bịch	10000.00	500000.00	hkn	98899	56	zdd	258	59h999	\N	t	1	\N	4982795.03	túi	65524.40	0.00
705	2024-11-27 02:26:08.931172+00	2024-11-27 02:26:08.931172+00	\N	\N	A8QD1M7BG0W0	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	50.00	1		10000.00	f	\N	0.00	5035000.00	178	túi rác	100000.00	5000000.00	hkn	868589	\N	\N	\N	\N	\N	f	1	\N	25000.00	túi	136971.10	\N
339	2024-11-20 08:27:14.156998+00	2024-11-20 08:27:14.156998+00	\N	khánh vũ 3	TDISDSY9CPV8	759	khánh vũ 3	\N	0.00	0.00	476	khánh	0968535468	79	777	27451	hẻm 56	10.84582761051965	107.05831674339302	477	khánh 4	09668656858	08	072	02221	hẻm 45	11.033250310249406	107.11628593083184	200.00	1	\N	\N	f	0.00	0.00	200000.00	138	nhôm	1000.00	200000.00	hkn	65959	\N	\N	\N	\N	\N	t	2	0.00	0.00	kí	\N	\N
340	2024-11-20 08:27:23.568244+00	2024-11-20 08:27:23.568244+00	\N	\N	GS7XYKOANY5W	756	Bảo đồng nát	58	11111.00	209900.00	475	Khanh	0192019283	02	024	00691	bao	10.935039177697119	106.91360526067567	468	Bảo dt	0869307209	79	764	26887	số 20	10.54272471248186	106.36659365492204	1.00	1		1111.00	t	0.10	1001222.20	11013444.20	134	sắt vụn	10000000.00	10000000.00	TNHH Đồng Nát	085236914725	\N	\N	\N	\N	\N	f	1	\N	11111.00	tấn	89495.20	\N
347	2024-11-20 09:04:15.511303+00	2024-11-20 09:04:27.050941+00	\N	linh siêu nhân	651N2KSAJY7K	760	linh siêu nhân	\N	0.00	0.00	478	linh	08694685828	06	060	01861	smdnfb	11.066623483668096	107.16087205363938	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	1.00	3	\N	\N	f	0.00	0.00	1000.00	139	rác bịch	1000.00	1000.00	hkn	98899	\N	\N	\N	\N	\N	t	2	0.00	0.00	túi	\N	\N
343	2024-11-20 08:56:36.936199+00	2024-11-20 08:56:36.936199+00	\N	linh siêu nhân	B6BD7D56RF1K	760	linh siêu nhân	\N	0.00	0.00	478	linh	08694685828	06	060	01861	smdnfb	11.066623483668096	107.16087205363938	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	111.00	1	\N	\N	t	10.00	11100.00	122100.00	139	rác bịch	1000.00	111000.00	hkn	98899	\N	\N	\N	\N	\N	t	2	0.00	0.00	túi	\N	\N
348	2024-11-20 09:05:53.380462+00	2024-11-20 09:06:09.093218+00	\N	linh siêu nhân	2WWS8JTMQRPG	760	linh siêu nhân	\N	0.00	0.00	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	111.00	3	\N	\N	f	0.00	0.00	111000.00	139	rác bịch	1000.00	111000.00	hkn	98899	\N	\N	\N	\N	\N	t	2	0.00	0.00	túi	\N	\N
304	2024-11-18 13:42:26.806617+00	2024-11-21 08:21:27.444102+00	\N	ab	1L6SUH1ZAS0Z	1	Mrs. Sara Abbott	1	1000000.00	500000.00	1	Dr. Sonja Christiansen	664-503-7747	79	769	26812	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	4	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	1111.00	1	\N	\N	t	0.00	0.00	2611000.00	4	nhựa dẻo	1000.00	1111000.00	a	b	\N	\N	\N	\N	\N	f	2	0.00	1500000.00		\N	\N
557	2024-11-21 06:34:45.899378+00	2024-11-21 09:24:15.001539+00	\N	linh siêu nhân	1HKVYNBBMF2I	760	linh siêu nhân	\N	0.00	1274401.44	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	478	linh	08694685828	06	060	01861	smdnfb	11.066623483668096	107.16087205363938	1.00	4	\N	\N	t	10.00	100.00	8231249.18	139	rác bịch	1000.00	1000.00	hkn	98899	\N	\N	\N	\N	\N	t	2	100.00	6955747.74	túi	\N	1.00
590	2024-11-21 06:41:27.606203+00	2024-11-21 06:43:16.305577+00	\N	hân nhã 70	Q2628IXYXMPO	796	hân nhã 70	61	10000.00	1000.00	550	hân	0668566693	10	084	02809	hdjdbc	10.716870004400937	106.97743131897184	583	hkn	0668696858	10	084	02812	hsjej	10.694681301624835	106.65093509942092	1.00	3	\N	\N	f	0.00	0.00	30000.00	140	cốt thép	1000.00	1000.00	hkn	879797	\N	\N	\N	\N	\N	f	2	0.00	10000.00	tấn	\N	\N
706	2024-11-27 02:34:07.413638+00	2024-11-27 02:45:57.535141+00	\N	\N	X5V6H3YN3V86	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	50.00	11		10000.00	f	\N	0.00	5035000.00	178	túi rác	100000.00	5000000.00	hkn	868589	172	nh27	432	60h4576	\N	f	1	\N	25000.00	túi	136971.10	51.00
425	2024-11-21 06:20:54.943935+00	2024-11-21 06:20:54.943935+00	\N	\N	V60A80BDTUTC	763	nhã hân 7	\N	\N	\N	484	hân	0896353866	01	001	00001	bsns	10.883022853969782	106.45823418547165	517	hân hkn	08638365696	11	099	03263	hkn1	10.384921982026151	106.81312537164855	20.00	1		500.00	f	\N	0.00	30000.00	134	sắt vụn	10000.00	200000.00	hkn	855646	\N	\N	\N	\N	\N	t	1	\N	\N	tấn	88504.80	\N
392	2024-11-21 06:13:19.117828+00	2024-11-21 06:13:19.117828+00	\N	\N	2XMUVXTQTOYI	740	hân lê 2	\N	\N	\N	463	han le	0834692563	01	002	00037	13 dươngd 100	10.756284421745871	106.85798460130704	464	dt	0897643251	02	024	00688	nsnsjsj	10.774371235468008	106.86845762301319	20.00	1		1000.00	f	\N	0.00	30000.00	126	dầu	2000000.00	40000000.00	hkn	6468989	\N	\N	\N	\N	\N	t	1	\N	\N	lít	49598.40	\N
342	2024-11-20 08:38:45.108146+00	2024-11-20 08:49:40.469078+00	\N	linh siêu nhân	BLANLCA892ZT	760	linh siêu nhân	\N	0.00	0.00	478	linh	08694685828	06	060	01861	smdnfb	11.066623483668096	107.16087205363938	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	100.00	3	\N	\N	f	0.00	0.00	30000.00	139	rác bịch	1000.00	100000.00	hkn	98899	\N	\N	\N	\N	\N	t	2	0.00	NaN	túi	\N	\N
719	2024-11-28 06:35:38.032167+00	2024-11-28 06:57:09.864407+00	\N	khách hàng mua tro	Z7RWJBHQM7PQ	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	4	\N	\N	f	0.00	0.00	120000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	90.00	10000.00	tấn	89827.80	90.00
345	2024-11-20 09:00:49.945507+00	2024-11-20 09:02:58.333068+00	\N	linh siêu nhân	1CKSJ0A2564L	760	linh siêu nhân	59	444.00	222.00	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	1.00	3	\N	\N	f	0.00	0.00	1666.00	139	rác bịch	1000.00	1000.00	hkn	98899	\N	\N	\N	\N	\N	f	2	0.00	444.00	túi	\N	\N
352	2024-11-20 09:30:57.69551+00	2024-11-20 09:31:17.023628+00	\N	linh siêu nhân	767X24IHUKB3	760	linh siêu nhân	\N	0.00	0.00	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	1.00	3	\N	\N	f	0.00	0.00	1000.00	139	rác bịch	1000.00	1000.00	hkn	98899	\N	\N	\N	\N	\N	t	2	0.00	0.00	túi	\N	\N
349	2024-11-20 09:09:08.226176+00	2024-11-20 09:56:40.200146+00	\N	\N	HI2GAXSMHY78	760	linh siêu nhân	\N	\N	0.00	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	1.00	11		10.00	f	\N	0.00	4739219.70	139	rác bịch	10000.00	10000.00	hkn	98899	57	bao moi	259	50H-12564	\N	t	1	\N	4729209.70	túi	65575.80	\N
389	2024-11-20 10:01:23.705307+00	2024-11-20 10:01:23.705307+00	\N	hân test đơn dự án	AJ0NOT07FBN4	761	hân test đơn dự án	\N	0.00	0.00	481	hân	0896358685	02	029	00880	hẻm 67	10.582577101881897	107.24205999081703	482	khánh	0896865865	04	047	01453	hẻm 98	10.78547043271833	107.119539193035	100.00	1	\N	\N	f	0.00	0.00	100000.00	140	cốt thép	1000.00	100000.00	hkn	9669899686	\N	\N	\N	\N	\N	t	2	0.00	0.00	tấn	\N	\N
341	2024-11-20 08:37:37.211588+00	2024-11-20 08:37:37.211588+00	\N	Bartoletti, Fay and O'Connell	GACKO4EUAPH4	1	Mrs. Sara Abbott	3	590000.00	250000.00	6	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	18	Stella Heathcote MD	922-319-0321	79	769	26800	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	8800.00	1	\N	\N	t	10.00	5280.00	898080.00	3	tro bay	6.00	52800.00	Mosciski and Sons	29031185	\N	\N	\N	\N	\N	f	2	0.00	840000.00	tấn	\N	\N
391	2024-11-20 10:21:36.757094+00	2024-11-20 10:21:36.757094+00	\N	hân test đơn dự án	C6PHA6EVAALD	761	hân test đơn dự án	\N	0.00	0.00	481	hân	0896358685	02	029	00880	hẻm 67	10.582577101881897	107.24205999081703	482	khánh	0896865865	04	047	01453	hẻm 98	10.78547043271833	107.119539193035	200.00	11	\N	\N	f	0.00	0.00	200000.00	140	cốt thép	1000.00	200000.00	hkn	9669899686	\N	\N	\N	\N	\N	t	2	0.00	0.00	tấn	4929535.10	\N
735	2024-11-29 07:57:11.912136+00	2024-11-29 08:40:10.035375+00	\N	\N	GE5RK1MGX1TB	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	50.00	11		100000.00	f	\N	\N	2110000.00	174	tro	40000.00	2000000.00	hkn	6858856	139	nh8	414	40h5794	\N	f	1	\N	10000.00	tấn	89827.80	50.00
355	2024-11-20 09:42:58.910005+00	2024-11-20 09:43:31.638398+00	\N	linh siêu nhân	6AAPWMUI7SAG	760	linh siêu nhân	\N	0.00	0.00	478	linh	08694685828	06	060	01861	smdnfb	11.066623483668096	107.16087205363938	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	11.00	3	\N	\N	f	0.00	0.00	11000.00	139	rác bịch	1000.00	11000.00	hkn	98899	\N	\N	\N	\N	\N	t	2	0.00	0.00	túi	\N	\N
356	2024-11-20 09:46:00.123253+00	2024-11-21 00:15:09.721932+00	\N	linh siêu nhân	LQ8RUK0SRRKT	760	linh siêu nhân	\N	0.00	1269843.12	478	linh	08694685828	06	060	01861	smdnfb	11.066623483668096	107.16087205363938	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	1.00	3	\N	\N	f	0.00	0.00	7051031.45	139	rác bịch	1000.00	1000.00	hkn	98899	\N	\N	\N	\N	\N	t	2	0.00	5780188.33	túi	\N	\N
707	2024-11-27 03:09:40.311845+00	2024-11-27 03:11:25.150285+00	\N	\N	1H40FNGIDUBH	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	50.00	11		1000.00	f	\N	0.00	5026000.00	178	túi rác	100000.00	5000000.00	hkn	868589	172	nh27	432	60h4576	\N	f	1	\N	25000.00	túi	136971.10	51.00
720	2024-11-28 07:14:33.576156+00	2024-11-28 07:43:28.76095+00	\N	khách hàng mua tro	ZI6UVP3XCF5U	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	11	\N	\N	f	0.00	0.00	150000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	100.00	10000.00	tấn	89827.80	100.00
390	2024-11-20 10:02:50.583587+00	2024-11-21 07:00:09.91347+00	\N	\N	G7PJIF5HHNQE	760	linh siêu nhân	\N	\N	\N	478	linh	08694685828	06	060	01861	smdnfb	11.066623483668096	107.16087205363938	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	20.00	5		500000.00	f	\N	0.00	6480188.33	139	rác bịch	10000.00	200000.00	hkn	98899	56	zdd	258	59h999	\N	t	1	\N	5780188.33	túi	178500.50	0.00
736	2024-11-29 08:08:27.836002+00	2024-11-29 08:34:31.190233+00	\N	\N	44741OKJI1UG	895	khách hàng mua tro	95	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	50.00	11		100000.00	f	\N	\N	2110000.00	174	tro	40000.00	2000000.00	hkn	6858856	139	nh8	414	40h5794	\N	f	1	\N	10000.00	tấn	89827.80	50.00
337	2024-11-20 07:10:55.634798+00	2024-11-21 08:24:26.335756+00	\N	hân nhã 	BCT3JL9WHFNR	757	hân nhã 	\N	0.00	0.00	471	hân	0986534589	01	005	00160	ngoz 78	10.672107826747656	106.83998376042432	472	hân	0664865864	44	456	19216	jsjd	10.857193238762989	107.17791282961322	100.00	3	\N	\N	t	10.00	10000.00	30000.00	136	sắt 1	1000.00	100000.00	hknc	867464897888	\N	\N	\N	\N	\N	t	2	1.39	NaN	kí	\N	\N
657	2024-11-21 08:55:02.640601+00	2024-11-21 08:55:02.640601+00	\N	\N	P6F6HQ5TLBLN	862	khách hàng mua hộp hàng	\N	\N	\N	616	hân	0965328456	02	024	00688	ngõ 67	10.910389142402487	106.30025114013249	650	lnh	0865386535	79	778	27484	dươngd 60	10.187465025525974	106.86075123546988	100.00	1		2555.00	t	\N	0.00	30000.00	141	hộp hàng	100000.00	10000000.00	hkn	123506884864	\N	\N	\N	\N	\N	t	1	\N	\N	hộp	151378.00	\N
344	2024-11-20 08:57:35.3803+00	2024-11-20 08:58:27.888573+00	\N	linh siêu nhân	QW7E2BAYZT2E	760	linh siêu nhân	\N	0.00	0.00	478	linh	08694685828	06	060	01861	smdnfb	11.066623483668096	107.16087205363938	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	1.00	3	\N	\N	f	0.00	0.00	30000.00	139	rác bịch	1000.00	1000.00	hkn	98899	\N	\N	\N	\N	\N	t	2	0.00	NaN	túi	\N	\N
753	2024-12-02 00:58:30.519523+00	2024-12-02 00:58:30.519523+00	\N	kh bug	246VV8OZI6J7	899	kh bug	97	12000.00	500000.00	661	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	662	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	123.00	1	\N	\N	t	10.00	12300.00	647300.00	180	bug	1000.00	123000.00	bug tnhh	3829083209	\N	\N	\N	\N	\N	f	2	0.00	512000.00	loi	99100.20	\N
752	2024-12-02 00:50:40.226918+00	2024-12-02 00:54:56.511683+00	\N	\N	TKK7DZDE7V36	899	kh bug	97	12000.00	500000.00	661	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	662	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	10.00	11		10222.00	t	0.10	5002222.20	55024444.20	180	bug	5000000.00	50000000.00	bug tnhh	3829083209	180	bao test	440	27H-99990	\N	f	1	\N	12000.00	loi	99100.20	10.00
708	2024-11-27 06:36:49.512598+00	2024-11-28 04:23:30.142085+00	\N	khách hàng mua tro	GKLLYHS0RQOC	895	khách hàng mua tro	95	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	11	\N	\N	f	0.00	0.00	140000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	100.00	10000.00	tấn	89827.80	100.00
672	2024-11-22 08:32:14.765195+00	2024-11-27 04:23:34.279104+00	\N	khách hàng mua tro	OS0UM1G0ADAN	895	khách hàng mua tro	\N	0.00	548825.94	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	652	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	10.00	11	\N	\N	f	0.00	0.00	1656477.82	174	tro	1000.00	10000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	120.00	3995793.82	tấn	\N	12.00
658	2024-11-21 09:35:09.51307+00	2024-11-21 09:35:09.51307+00	\N	linh siêu nhân	3RUVV2DH7O3E	760	linh siêu nhân	60	1000.00	20000.00	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	1000.00	1	\N	\N	f	0.00	0.00	1021000.00	139	rác bịch	1000.00	1000000.00	hkn	98899	\N	\N	\N	\N	\N	f	2	0.00	21000.00	túi	\N	\N
673	2024-11-22 09:21:04.278093+00	2024-11-25 03:13:51.932607+00	\N	khách hàng mua tro	1EWYT6EHS2DM	895	khách hàng mua tro	\N	0.00	347635.86	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	654	hkn2	09683953683	64	623	23617	55 hai bà trưng	10.903530872106048	106.5675667739202	10.00	4	\N	\N	f	0.00	0.00	4419726.08	174	tro	1000.00	10000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	20.00	4062090.22	tấn	\N	2.00
662	2024-11-22 04:26:04.166219+00	2024-11-22 07:34:12.073139+00	\N	khách hàng mua tro	2ODEAZBZ4WXY	895	khách hàng mua tro	\N	0.00	NaN	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	652	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	100.00	3	\N	\N	f	0.00	0.00	30000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	0.00	NaN	tấn	\N	\N
660	2024-11-21 09:51:45.095004+00	2024-11-21 09:51:45.095004+00	\N	Ledner, Turner and Trantow	LV0CTPXAM54J	756	Bảo đồng nát	\N	0.00	0.00	6	Mrs. Beverly Bednar	302-755-3749	79	769	27112	14 đường 100, Phường Thạnh Mỹ Lợi, Thủ Đức, Hồ Chí Minh 71114, Việt Nam	10.770024727695503	106.76844721043359	8	Angel Kiehn	216-213-8480	79	769	26818	11/6 Đ. số 5, khu phố 3, Thủ Đức, Hồ Chí Minh 700000, Việt Nam	10.856291486212898	106.75347156918602	8800.00	1	\N	\N	t	10.00	8800.00	96800.00	3	tro bay	10.00	88000.00	Dietrich LLC	40103638	\N	\N	\N	\N	\N	t	2	0.00	0.00	tấn	\N	\N
623	2024-11-21 06:44:48.332252+00	2024-11-22 04:26:44.085632+00	\N	Wilderman LLC	QO86UC5CSAKH	756	Bảo đồng nát	\N	0.00	98052.24	6	Mrs. Beverly Bednar	302-755-3749	79	769	27112	14 đường 100, Phường Thạnh Mỹ Lợi, Thủ Đức, Hồ Chí Minh 71114, Việt Nam	10.770024727695503	106.76844721043359	8	Angel Kiehn	216-213-8480	79	769	26818	11/6 Đ. số 5, khu phố 3, Thủ Đức, Hồ Chí Minh 700000, Việt Nam	10.856291486212898	106.75347156918602	3800.00	11	\N	\N	t	10.00	8800.00	3631905.83	3	tro bay	10.00	88000.00	Kessler, Treutel and Mills	00075436	\N	\N	\N	\N	\N	t	2	105.63	3437053.59	tấn	\N	4014.00
661	2024-11-21 10:03:38.138373+00	2024-11-21 10:25:47.509343+00	\N	khách hàng mua tro	NEQPHBLNUZYF	895	khách hàng mua tro	\N	0.00	548825.94	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	652	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	50.00	4	\N	\N	f	0.00	0.00	4594619.76	174	tro	1000.00	50000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	80.00	3995793.82	tấn	\N	40.00
663	2024-11-22 07:31:22.79884+00	2024-11-22 07:31:22.79884+00	\N	khách hàng mua tro	SN3TOT0QJ7PD	895	khách hàng mua tro	\N	0.00	0.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	652	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	100.00	1	\N	\N	f	0.00	0.00	100000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	0.00	0.00	tấn	\N	\N
721	2024-11-28 07:52:48.763915+00	2024-11-28 08:01:53.55092+00	\N	\N	7ZE4J55T3Y9J	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	50.00	11		1000.00	f	\N	\N	2011000.00	174	tro	40000.00	2000000.00	hkn	6858856	139	nh8	414	40h5794	\N	f	1	\N	10000.00	tấn	89827.80	51.00
668	2024-11-22 08:09:14.861628+00	2024-11-22 08:10:28.990558+00	\N	khách hàng mua tro	5GJA5S6TQFRE	895	khách hàng mua tro	\N	0.00	\N	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	652	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	10.00	3	\N	\N	f	0.00	0.00	30000.00	174	tro	1000.00	10000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	0.00	\N	tấn	\N	\N
670	2024-11-22 08:22:42.427524+00	2024-11-25 02:56:49.394557+00	\N	khách hàng mua tro	6SQ1UU1L1K84	895	khách hàng mua tro	\N	0.00	548825.94	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	652	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	10.00	4	\N	\N	f	0.00	0.00	4554619.76	174	tro	1000.00	10000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	60.00	3995793.82	tấn	\N	6.00
669	2024-11-22 08:15:55.524595+00	2024-11-25 03:23:36.48063+00	\N	khách hàng mua tro	IG4XYHXB7EPU	895	khách hàng mua tro	\N	0.00	548825.94	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	652	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	10.00	4	\N	\N	f	0.00	0.00	4554619.76	174	tro	1000.00	10000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	60.00	3995793.82	tấn	\N	6.00
667	2024-11-22 08:01:40.865608+00	2024-11-22 08:01:59.528605+00	\N	linh siêu nhân	RVLAH2BLQOOQ	760	linh siêu nhân	\N	0.00	511491.24	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	1.00	3	\N	\N	f	0.00	0.00	5241687.24	139	rác bịch	1000.00	1000.00	hkn	98899	\N	\N	\N	\N	\N	t	2	0.00	4729196.00	túi	\N	\N
754	2024-12-02 01:01:05.266035+00	2024-12-02 01:01:05.266035+00	\N	kh bug	MUSM6MDTVYAZ	899	kh bug	97	12000.00	500000.00	661	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	662	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	123.00	1	\N	\N	t	10.00	12300.00	647300.00	180	bug	1000.00	123000.00	bug tnhh	3829083209	\N	\N	\N	\N	\N	f	2	0.00	512000.00	loi	99100.20	\N
671	2024-11-22 08:28:45.776178+00	2024-11-22 09:04:34.987868+00	\N	khách hàng mua tro	57A4E0DBO4Y1	895	khách hàng mua tro	\N	0.00	347635.86	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	654	hkn2	09683953683	64	623	23617	55 hai bà trưng	10.903530872106048	106.5675667739202	10.00	12	\N	\N	f	0.00	0.00	4425379.94	174	tro	1000.00	10000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	100.00	4067744.08	tấn	\N	10.00
737	2024-11-30 07:23:01.703788+00	2024-11-30 07:26:39.395208+00	\N	\N	TWBCFYFV8Q0D	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	50.00	11		1000.00	f	\N	\N	2011000.00	174	tro	40000.00	2000000.00	hkn	6858856	139	nh8	414	40h5794	\N	f	1	\N	10000.00	tấn	89827.80	50.00
666	2024-11-22 07:56:30.724087+00	2024-11-25 03:38:14.295485+00	\N	khách hàng mua tro	GW6C83KLQ0SS	895	khách hàng mua tro	\N	0.00	548825.94	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	652	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	12.00	4	\N	\N	t	10.00	1200.00	4557819.76	174	tro	1000.00	12000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	50.00	3995793.82	tấn	\N	6.00
674	2024-11-22 09:38:36.743087+00	2024-11-22 09:45:09.063706+00	\N	khách hàng mua tro	XUYTXU31B03F	895	khách hàng mua tro	\N	0.00	680812.86	652	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	10.00	3	\N	\N	f	0.00	0.00	4831993.72	174	tro	1000.00	10000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	90.00	4141180.86	tấn	\N	9.00
684	2024-11-25 07:54:29.135326+00	2024-11-26 03:32:08.300455+00	\N	khách hàng mua tro	FWTUTMMA8ZKL	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	4	\N	\N	f	0.00	0.00	120000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	100.00	10000.00	tấn	\N	100.00
664	2024-11-22 07:44:51.404003+00	2024-11-25 03:08:40.980915+00	\N	Labadie - Konopelski	TPJDHU3NNOBZ	756	Bảo đồng nát	\N	0.00	98052.24	6	Mrs. Beverly Bednar	302-755-3749	79	769	27112	14 đường 100, Phường Thạnh Mỹ Lợi, Thủ Đức, Hồ Chí Minh 71114, Việt Nam	10.770024727695503	106.76844721043359	8	Angel Kiehn	216-213-8480	79	769	26818	11/6 Đ. số 5, khu phố 3, Thủ Đức, Hồ Chí Minh 700000, Việt Nam	10.856291486212898	106.75347156918602	3000.00	4	\N	\N	f	0.00	0.00	3565096.47	3	tro bay	10.00	30000.00	Lindgren - Mitchell	15319797	\N	\N	\N	\N	\N	t	2	36.67	3437044.23	tấn	\N	1100.00
680	2024-11-25 04:27:21.944633+00	2024-11-27 04:22:07.746796+00	\N	khách hàng mua tro	XUV8L2YOAJ8T	895	khách hàng mua tro	\N	0.00	700656.84	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	10.00	11	\N	\N	f	0.00	0.00	2111970.52	174	tro	1000.00	10000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	100.00	4223902.28	tấn	\N	10.00
677	2024-11-23 04:03:54.419929+00	2024-11-26 10:02:51.405677+00	\N	\N	HAKMHPDVIECG	896	khách hàng nón lá	\N	\N	\N	655	hkn	0968685686	11	097	03178	bdhd	10.487121165685204	106.5979298185143	656	hkn2	8865949565	45	468	19600	hdnfnfjfif	10.337661780271675	107.15084608993939	100.00	11		1000.00	f	\N	0.00	14967435.75	177	nón lá	100000.00	10000000.00	hkn	787664846446	150	hn1	426	40h7746	\N	t	1	\N	4966435.75	cái	125702.70	1000.00
678	2024-11-25 04:03:15.200631+00	2024-11-25 04:03:15.200631+00	\N	khách hàng mua tro	SK3KRIVTLO65	895	khách hàng mua tro	\N	0.00	0.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	1	\N	\N	f	0.00	0.00	100000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	0.00	0.00	tấn	\N	\N
679	2024-11-25 04:25:21.117549+00	2024-11-25 04:25:21.117549+00	\N	linh siêu nhân	MOCVYFVOIJKD	760	linh siêu nhân	60	1000.00	20000.00	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	10.00	1	\N	\N	f	0.00	0.00	31000.00	139	rác bịch	1000.00	10000.00	hkn	98899	\N	\N	\N	\N	\N	f	2	0.00	21000.00	túi	\N	\N
682	2024-11-25 06:56:30.940493+00	2024-11-25 07:14:54.243209+00	\N	khách hàng mua tro	GNKR0NPE89S0	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	12	\N	\N	f	0.00	0.00	120000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	80.00	10000.00	tấn	\N	80.00
683	2024-11-25 07:17:47.039958+00	2024-11-27 04:17:18.904716+00	\N	khách hàng mua tro	64L1VIGOIFRI	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	11	\N	\N	f	0.00	0.00	140000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	120.00	10000.00	tấn	\N	120.00
676	2024-11-23 02:40:56.185175+00	2024-11-23 02:40:56.185175+00	\N	\N	WAXVEV6I4HYM	895	khách hàng mua tro	\N	\N	\N	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	10.00	1		1000.00	t	\N	0.00	30000.00	174	tro	40000.00	400000.00	hkn	6858856	\N	\N	\N	\N	\N	t	1	\N	\N	tấn	89827.80	\N
709	2024-11-27 07:11:05.553903+00	2024-11-27 07:43:01.241449+00	\N	khách hàng mua tro	368U47TXNMQU	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	11	\N	\N	f	0.00	0.00	140000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	100.00	10000.00	tấn	89827.80	100.00
685	2024-11-25 08:26:22.176116+00	2024-11-25 08:26:22.176116+00	\N	Jacobi - Fisher	VPAZRFIRSBY7	756	Bảo đồng nát	\N	0.00	0.00	6	Mrs. Beverly Bednar	302-755-3749	79	769	27112	14 đường 100, Phường Thạnh Mỹ Lợi, Thủ Đức, Hồ Chí Minh 71114, Việt Nam	10.770024727695503	106.76844721043359	8	Angel Kiehn	216-213-8480	79	769	26818	11/6 Đ. số 5, khu phố 3, Thủ Đức, Hồ Chí Minh 700000, Việt Nam	10.856291486212898	106.75347156918602	3000.00	1	\N	\N	f	0.00	0.00	30000.00	3	tro bay	10.00	30000.00	Roob - Lind	73773326	\N	\N	\N	\N	\N	t	2	0.00	0.00	tấn	12570.80	\N
686	2024-11-25 08:27:13.502544+00	2024-11-25 08:27:13.502544+00	\N	Hamill - Yost	3X4ISAV9EKI7	756	Bảo đồng nát	3	0.00	0.00	6	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	18	Stella Heathcote MD	922-319-0321	79	769	26800	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	3000.00	1	\N	\N	f	0.00	0.00	30000.00	3	tro bay	10.00	30000.00	Mayert - Auer	55034413	\N	\N	\N	\N	\N	t	2	0.00	0.00	tấn	3303.00	\N
710	2024-11-27 07:47:04.897742+00	2024-11-27 08:59:13.894891+00	\N	khách hàng mua tro	3FZ767AQ51GY	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	11	\N	\N	f	0.00	0.00	150000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	120.00	10000.00	tấn	89827.80	120.00
687	2024-11-25 08:36:58.826851+00	2024-11-25 08:36:58.826851+00	\N	\N	H7WS5FFZJ47I	760	linh siêu nhân	60	1000.00	20000.00	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	100.00	1		1000.00	f	\N	0.00	1002000.00	139	rác bịch	10000.00	1000000.00	hkn	98899	\N	\N	\N	\N	\N	f	1	\N	1000.00	túi	65524.40	\N
665	2024-11-22 07:53:33.502399+00	2024-11-22 07:54:09.805618+00	\N	khách hàng mua tro	QW2LLVU5OIMP	895	khách hàng mua tro	\N	0.00	NaN	652	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	10.00	3	\N	\N	f	0.00	0.00	30000.00	174	tro	1000.00	10000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	0.00	NaN	tấn	\N	\N
329	2024-11-19 09:14:05.786548+00	2024-11-20 02:49:04.218082+00	\N	\N	3MPCAJU4MHAL	640	Bao AE	\N	\N	\N	455	Bao B	0984736251	02	027	00778	Binh tan 456	10.257381823872283	106.88753744246766	455	Bao A	098765463	02	027	00778	34 an lac	10.597808625303523	106.51728802735788	1.00	1		1111.00	f	\N	0.00	30000.00	20	tiêu dùng	8000000.00	270000000.00	hknko	19389183813	\N	\N	\N	\N	\N	t	1	\N	\N	cái	50923.90	\N
723	2024-11-28 08:37:56.740059+00	2024-11-28 08:43:21.159389+00	\N	\N	C4DC77FRADEU	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	50.00	11		1000.00	f	\N	\N	2011000.00	174	tro	40000.00	2000000.00	hkn	6858856	139	nh8	414	40h5794	\N	f	1	\N	10000.00	tấn	89827.80	50.00
301	2024-11-18 13:38:28.020102+00	2024-11-21 03:07:50.387405+00	\N	\N	5D0VJ50DDLYP	7	ab	\N	\N	\N	22	ab	12121212	01	001	00001	ab	13.8127	-7.1436	22	a Linh	0987654342	01	001	00006	2 ba trung	66.1809	21.9767	12.00	1		111.00	f	\N	0.00	30000.00	1	tiêu dùng	1000.00	1800.00	12345	ab	\N	\N	\N	\N	\N	t	1	\N	20000.00	tấn	4929535.10	\N
697	2024-11-25 20:56:01.7638+00	2024-11-26 07:42:29.33413+00	\N	KH 100	VL37DKF4URUA	897	KH 100	\N	0.00	1010699.66	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	100.00	11	\N	\N	t	10.00	10000.00	8195597.28	178	túi rác	1000.00	100000.00	hkn	868589	\N	\N	\N	\N	\N	t	2	109.00	4782206.53	túi	136971.10	109.00
689	2024-11-25 08:37:36.200551+00	2024-11-26 07:51:20.861726+00	\N	\N	U2EQWZ2XKK6V	760	linh siêu nhân	60	1000.00	20000.00	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	10.00	11		1000.00	f	\N	0.00	102000.00	139	rác bịch	10000.00	100000.00	hkn	98899	57	bao moi	259	50H-12564	\N	f	1	\N	1000.00	túi	65524.40	10.00
722	2024-11-28 08:25:48.618591+00	2024-11-28 08:37:11.661272+00	\N	khách hàng mua tro	A8I4MV2T532Z	895	khách hàng mua tro	\N	0.00	548825.94	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	652	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	100.00	11	\N	\N	f	0.00	0.00	2844129.70	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	100.00	3995838.12	tấn	70362.30	100.00
698	2024-11-26 04:08:13.958658+00	2024-11-26 04:08:13.958658+00	\N	\N	2M41X8IKGW98	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	100.00	1		50000.00	t	0.10	1007500.00	11082500.00	178	túi rác	100000.00	10000000.00	hkn	868589	\N	\N	\N	\N	\N	f	1	\N	25000.00	túi	136971.10	\N
491	2024-11-21 06:28:54.72115+00	2024-11-21 06:28:54.72115+00	\N	\N	MNC60HZE3G8D	760	linh siêu nhân	59	444.00	222.00	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	20.00	1		5000.00	f	\N	0.00	205444.00	139	rác bịch	10000.00	200000.00	hkn	98899	\N	\N	\N	\N	\N	f	1	\N	444.00	túi	65575.80	\N
711	2024-11-27 08:54:38.221748+00	2024-11-27 09:44:45.568601+00	\N	khách hàng mua tro	VLLFTFBTUCOH	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	4	\N	\N	f	0.00	0.00	120000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	40.00	10000.00	tấn	89827.80	40.00
326	2024-11-19 08:54:29.450792+00	2024-11-26 10:12:28.917749+00	\N	\N	P955EA8DXN47	740	hân lê 2	\N	\N	\N	464	dt	0897643251	02	024	00688	nsnsjsj	10.774371235468008	106.86845762301319	463	han le	0834692563	01	002	00037	13 dươngd 100	10.756284421745871	106.85798460130704	1.00	11		1.00	f	\N	0.00	5938078.83	126	dầu	2000000.00	2000000.00	hkn	6468989	19	Ciara98	19	50H-17031	50H-27031	t	1	\N	3938077.83	lít	47504.50	0.00
738	2024-11-30 21:49:44.492401+00	2024-12-01 04:32:54.312061+00	\N	KH 100	5K8J0H03TY6X	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	120.00	3	\N	\N	t	10.00	12000.00	657000.00	178	túi rác	1000.00	120000.00	hkn	868589	\N	\N	\N	\N	\N	f	2	0.00	25000.00	túi	136971.10	\N
325	2024-11-19 08:54:28.952296+00	2024-11-20 04:01:46.621302+00	\N	\N	5Y2CXP0G428E	740	hân lê 2	\N	\N	\N	463	han le	0834692563	01	002	00037	13 dươngd 100	10.756284421745871	106.85798460130704	464	dt	0897643251	02	024	00688	nsnsjsj	10.774371235468008	106.86845762301319	1.00	3		1.00	f	\N	0.00	5778279.64	126	dầu	2000000.00	2000000.00	hkn	6468989	21	Bradford_Wuckert34	21	50H-17026	50H-27026	t	1	\N	3778278.64	lít	47504.50	\N
302	2024-11-18 13:40:37.360744+00	2024-11-18 13:40:37.360744+00	\N	\N	5MZH12D60ADK	7	ab	10	20000.00	30000.00	85	gv	08888888	01	002	00040	8888	66.1809	21.9767	22	ab	12121212	01	001	00001	ab	13.8127	-7.1436	1111.00	1		1111.00	f	\N	0.00	22241111.00	6	cát 2	20000.00	22220000.00	12345	ab	\N	\N	\N	\N	\N	f	1	\N	20000.00	khối	4929535.10	\N
691	2024-11-25 09:16:22.545704+00	2024-11-25 09:16:22.545704+00	\N	\N	992QX13E8VEM	760	linh siêu nhân	60	1000.00	20000.00	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	10.00	1		1000.00	f	\N	0.00	102000.00	139	rác bịch	10000.00	100000.00	hkn	98899	\N	\N	\N	\N	\N	f	1	\N	1000.00	túi	65524.40	\N
324	2024-11-19 08:51:27.979155+00	2024-11-19 08:52:12.595331+00	\N	\N	UAIRCOTLZZ4W	740	hân lê 2	\N	\N	\N	463	han le	0834692563	01	002	00037	13 dươngd 100	10.756284421745871	106.85798460130704	464	dt	0897643251	02	024	00688	nsnsjsj	10.774371235468008	106.86845762301319	1.00	3		1.00	f	\N	0.00	5778279.64	126	dầu	2000000.00	2000000.00	hkn	6468989	20	Vern78	20	50H-17033	50H-27033	t	1	\N	3778278.64	lít	49598.40	\N
746	2024-12-01 04:36:46.007521+00	2024-12-01 04:48:47.551166+00	\N	Boyle LLC	SVQJ8XVOQZMH	1	Mrs. Sara Abbott	3	590000.00	250000.00	6	Mattie Runolfsson	340-533-8788	79	769	26824	Nhà máy nhiệt điện Vĩnh Tân 1, 8R95+833, Vĩnh Tân, Tuy Phong, Bình Thuận, Việt Nam	11.318268349608726	108.80767019706198	18	Stella Heathcote MD	922-319-0321	79	769	26800	Công Ty TNHH MTV Xi Măng Hạ Long, JQJ6+PWR, Đường số 11, Hiệp Phước, Nhà Bè, Hồ Chí Minh, Việt Nam	10.631851822846356	106.76225619460048	123.00	11	\N	\N	t	10.00	73.80	1590811.80	3	tro bay	6.00	738.00	Bailey Group	82526700	\N	\N	\N	\N	\N	f	2	123.58	590000.00	tấn	3303.00	152.00
755	2024-12-02 01:03:15.929066+00	2024-12-02 02:18:04.527909+00	\N	kh bug	NCOD17UIL2KR	899	kh bug	97	12000.00	500000.00	661	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	662	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	123.00	11	\N	\N	f	0.00	0.00	617512000.00	180	bug	5000000.00	615000000.00	bug tnhh	3829083209	\N	\N	\N	\N	\N	f	2	100.00	12000.00	loi	99100.20	123.00
321	2024-11-19 08:37:03.833844+00	2024-11-19 08:37:33.681494+00	\N	\N	HQSUB54W6MIY	740	hân lê 2	56	20000.00	1000.00	463	han le	0834692563	01	002	00037	13 dươngd 100	10.756284421745871	106.85798460130704	464	dt	0897643251	02	024	00688	nsnsjsj	10.774371235468008	106.86845762301319	1.00	3		100.00	f	\N	0.00	20200.00	126	dầu	100.00	100.00	hkn	6468989	17	Nicola.Lowe	17	50H-17030	50H-27030	f	1	\N	20000.00	lít	49598.40	\N
323	2024-11-19 08:43:09.620281+00	2024-11-19 08:49:21.772182+00	\N	\N	X4SK65AQY2JT	740	hân lê 2	\N	\N	\N	463	han le	0834692563	01	002	00037	13 dươngd 100	10.756284421745871	106.85798460130704	464	dt	0897643251	02	024	00688	nsnsjsj	10.774371235468008	106.86845762301319	40.00	3		50000.00	f	\N	0.00	5828278.64	3	tro bay	50000.00	2000000.00	Rogelio Kuhn	451-387-3653	20	Vern78	20	50H-17033	50H-27033	t	1	\N	3778278.64	tấn	49598.40	\N
740	2024-11-30 22:11:55.539619+00	2024-12-01 00:54:21.095228+00	\N	\N	0RE5LO4KL6T9	899	kh bug	97	12000.00	500000.00	661	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	662	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	10.00	11		11111.00	f	\N	\N	50023111.00	180	bug	5000000.00	50000000.00	bug tnhh	3829083209	180	bao test	440	27H-99990	\N	f	1	\N	12000.00	loi	99100.20	10.00
696	2024-11-25 10:07:36.223013+00	2024-11-26 10:25:28.126585+00	\N	\N	7AXVS1OBQ5SH	897	KH 100	\N	\N	\N	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	10.00	11		1000.00	f	\N	0.00	5777553.55	178	túi rác	100000.00	1000000.00	hkn	868589	163	nh22	423	60h3489	\N	t	1	\N	4776553.55	túi	136971.10	1000.00
319	2024-11-19 08:09:19.62895+00	2024-11-19 08:09:19.62895+00	\N	\N	13S0CEJFFDYR	739	hân lê	55	5000.00	20000.00	461	han le	0346249553	79	769	26818	54 đường số 2	10.82124242881269	106.4844112161959	462	han han	0346249532	62	617	23416	nguyễn bỉnh khiêm	10.548956207761467	106.75198987759788	200.00	1		100000.00	f	\N	0.00	400105000.00	124	dầu	2000000.00	400000000.00	hkn	45673186835	\N	\N	\N	\N	\N	f	1	\N	5000.00	lít	61526.50	\N
712	2024-11-28 01:22:20.126603+00	2024-11-28 01:22:20.126603+00	\N	\N	D3RO1U5MAJN1	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	100.00	1		100000.00	f	\N	\N	10125000.00	178	túi rác	100000.00	10000000.00	hkn	868589	\N	\N	\N	\N	\N	f	1	\N	25000.00	túi	136971.10	\N
724	2024-11-28 08:48:37.517293+00	2024-11-28 08:56:51.954951+00	\N	khách hàng mua tro	AZI014BFB5U6	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	11	\N	\N	f	0.00	0.00	140000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	100.00	10000.00	tấn	89827.80	100.00
713	2024-11-28 01:37:26.451909+00	2024-11-28 05:56:04.912737+00	\N	KH 100	9BSAOA5SF069	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	100.00	11	\N	\N	t	10.00	10000.00	3135000.00	178	túi rác	1000.00	100000.00	hkn	868589	\N	\N	\N	\N	\N	f	2	102.00	25000.00	túi	136971.10	102.00
725	2024-11-28 08:57:56.665878+00	2024-11-28 09:02:44.200308+00	\N	khách hàng mua tro	0LBE42VS7PV3	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	11	\N	\N	f	0.00	0.00	140000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	100.00	10000.00	tấn	89827.80	100.00
739	2024-11-30 22:01:33.358564+00	2024-11-30 22:01:33.358564+00	\N	\N	ECMNKHLOJQY5	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	23.00	1		11111.00	t	0.10	233611.10	2569722.10	178	túi rác	100000.00	2300000.00	hkn	868589	\N	\N	\N	\N	\N	f	1	\N	25000.00	túi	136971.10	\N
688	2024-11-25 08:37:35.514767+00	2024-11-25 08:37:35.514767+00	\N	\N	SXKJPT0CQNWJ	760	linh siêu nhân	60	1000.00	20000.00	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	10.00	1		1000.00	f	\N	0.00	102000.00	139	rác bịch	10000.00	100000.00	hkn	98899	\N	\N	\N	\N	\N	f	1	\N	1000.00	túi	65524.40	\N
690	2024-11-25 09:15:53.119531+00	2024-11-25 09:15:53.119531+00	\N	\N	QEZ0HFN5K02V	760	linh siêu nhân	60	1000.00	20000.00	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	1000.00	1		10000.00	f	\N	0.00	10011000.00	139	rác bịch	10000.00	10000000.00	hkn	98899	\N	\N	\N	\N	\N	f	1	\N	1000.00	túi	65524.40	\N
656	2024-11-21 08:55:02.113314+00	2024-11-21 08:55:02.113314+00	\N	\N	RDQ8JF748D67	862	khách hàng mua hộp hàng	\N	\N	\N	616	hân	0965328456	02	024	00688	ngõ 67	10.910389142402487	106.30025114013249	650	lnh	0865386535	79	778	27484	dươngd 60	10.187465025525974	106.86075123546988	100.00	1		2555.00	t	\N	0.00	30000.00	141	hộp hàng	100000.00	10000000.00	hkn	123506884864	\N	\N	\N	\N	\N	t	1	\N	\N	hộp	151378.00	\N
742	2024-12-01 01:43:10.893031+00	2024-12-01 03:25:16.754853+00	\N	\N	4O7V72E684B9	899	kh bug	97	12000.00	500000.00	661	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	662	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	1.00	11		2222.00	f	\N	\N	5014222.00	180	bug	5000000.00	5000000.00	bug tnhh	3829083209	180	bao test	440	27H-99990	\N	f	1	\N	12000.00	loi	99100.20	1.00
741	2024-12-01 01:30:09.948799+00	2024-12-01 01:42:19.880717+00	\N	\N	YFJ7E1KKWC3P	899	kh bug	97	12000.00	500000.00	661	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	662	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	11.00	5		1111.00	f	\N	\N	55013111.00	180	bug	5000000.00	55000000.00	bug tnhh	3829083209	180	bao test	440	27H-99990	\N	f	1	\N	12000.00	loi	99100.20	11.00
750	2024-12-01 05:35:42.282318+00	2024-12-01 08:02:45.398032+00	\N	kh bug	FNCN57AUORXS	899	kh bug	97	12000.00	500000.00	661	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	662	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	123.00	3	\N	\N	f	0.00	0.00	2135000.00	180	bug	1000.00	123000.00	bug tnhh	3829083209	\N	\N	\N	\N	\N	f	2	100.81	12000.00	loi	99100.20	124.00
756	2024-12-02 02:28:58.100987+00	2024-12-02 02:54:43.524114+00	\N	kh bug	OOOWJLT9EH89	899	kh bug	97	12000.00	500000.00	661	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	662	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	123.00	11	\N	\N	t	10.00	61500000.00	677012000.00	180	bug	5000000.00	615000000.00	bug tnhh	3829083209	\N	\N	\N	\N	\N	f	2	105.69	12000.00	loi	99100.20	130.00
524	2024-11-21 06:32:39.093215+00	2024-11-21 07:12:46.273524+00	\N	\N	97E79VC2WNMA	760	linh siêu nhân	60	1000.00	20000.00	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	1.00	5		100.00	f	\N	0.00	11100.00	139	rác bịch	10000.00	10000.00	hkn	98899	57	bao moi	259	50H-12564	\N	f	1	\N	1000.00	túi	65524.40	0.00
681	2024-11-25 06:31:58.786832+00	2024-11-25 08:30:32.26598+00	\N	\N	F183ZFF3K800	760	linh siêu nhân	60	1000.00	20000.00	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	10.00	5		4000.00	f	\N	0.00	105000.00	139	rác bịch	10000.00	100000.00	hkn	98899	57	bao moi	259	50H-12564	\N	f	1	\N	1000.00	túi	65524.40	10.00
695	2024-11-25 10:03:22.765423+00	2024-11-25 10:03:22.765423+00	\N	\N	XMHUWVN9LBNO	760	linh siêu nhân	60	1000.00	20000.00	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	10.00	1		1000.00	f	\N	0.00	102000.00	139	rác bịch	10000.00	100000.00	hkn	98899	\N	\N	\N	\N	\N	f	1	\N	1000.00	túi	65524.40	\N
267	2024-11-18 08:01:28.115816+00	2024-11-21 02:41:18.248633+00	\N	\N	HO2CSN3YZH6K	7	ab	10	20000.00	30000.00	85	gv	08888888	01	002	00040	8888	66.1809	21.9767	22	ab	12121212	01	001	00001	ab	13.8127	-7.1436	20.00	1		100.00	f	\N	0.00	30000.00	1	tiêu dùng	8000000.00	160000000.00	12345	ab	\N	\N	\N	\N	\N	t	1	\N	200.00	tấn	0.00	\N
316	2024-11-19 07:57:21.763241+00	2024-11-19 07:57:21.763241+00	\N	\N	VO88915ZCJP6	640	Bao AE	52	11111.00	11121.00	453	CDE	0987172653	02	027	00778	1233 an lac	75.40992120072153	-28.441733667395425	452	Han	0987654362	02	027	00778	28.mn	19.691929768498895	-94.33867854826099	124.00	1		1111.00	t	\N	0.00	30000.00	20	tiêu dùng	8000000.00	992000000.00	hknko	19389183813	\N	\N	\N	\N	\N	t	1	\N	\N	cái	0.00	\N
675	2024-11-23 02:40:55.73009+00	2024-11-23 02:40:55.73009+00	\N	\N	PBJOVZAE0EOX	895	khách hàng mua tro	\N	\N	\N	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	10.00	1		1000.00	t	\N	0.00	30000.00	174	tro	40000.00	400000.00	hkn	6858856	\N	\N	\N	\N	\N	t	1	\N	\N	tấn	89827.80	\N
322	2024-11-19 08:38:28.239603+00	2024-11-19 08:38:28.239603+00	\N	\N	96SDPZWN5E22	740	hân lê 2	\N	\N	\N	464	dt	0897643251	02	024	00688	nsnsjsj	10.774371235468008	106.86845762301319	463	han le	0834692563	01	002	00037	13 dươngd 100	10.756284421745871	106.85798460130704	1.00	1		100.00	f	\N	0.00	30000.00	126	dầu	10000.00	10000.00	hkn	6468989	\N	\N	\N	\N	\N	t	1	\N	\N	lít	47504.50	\N
309	2024-11-19 06:44:10.241886+00	2024-11-19 06:44:10.241886+00	\N	\N	TOYGGRRS2Q7N	640	Bao AE	\N	\N	\N	353	bao	0987584732	02	027	00772	so 14	13.8127	-7.1436	353	bao	0987584732	02	027	00772	so 14	13.8127	-7.1436	10000.00	1		100000.00	t	\N	0.00	30000.00	58	tro bay 6	1000000.00	10000000000.00	hknko	19389183813	\N	\N	\N	\N	\N	t	1	\N	\N	tấn	0.00	\N
351	2024-11-20 09:22:42.553395+00	2024-11-20 09:22:42.553395+00	\N	\N	4DYO8LY3BEVP	760	linh siêu nhân	59	444.00	222.00	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	11.00	1		1111.00	f	\N	0.00	30000.00	139	rác bịch	10000.00	110000.00	hkn	98899	\N	\N	\N	\N	\N	t	1	\N	\N	túi	65575.80	\N
311	2024-11-19 07:14:43.623034+00	2024-11-19 07:14:43.623034+00	\N	\N	6FB0XTKZUQP0	640	Bao AE	\N	\N	\N	353	bao	0987584732	02	027	00772	so 14	13.8127	-7.1436	353	bao	0987584732	02	027	00772	so 14	13.8127	-7.1436	11.00	1		1111.00	t	\N	0.00	30000.00	25	xi than	79999900.00	879998900.00	hknko	19389183813	\N	\N	\N	\N	\N	t	1	\N	\N	khoi	0.00	\N
346	2024-11-20 09:04:06.38451+00	2024-11-20 09:04:06.38451+00	\N	\N	Y06E5XW7ATB7	760	linh siêu nhân	\N	\N	\N	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	1.00	1		11.00	f	\N	0.00	30000.00	139	rác bịch	10000.00	10000.00	hkn	98899	\N	\N	\N	\N	\N	t	1	\N	\N	túi	65575.80	\N
307	2024-11-18 13:47:52.010924+00	2024-11-21 03:22:53.236296+00	\N	\N	Q6KQ268NXFXD	7	ab	\N	\N	\N	251	a Linh	0987654342	01	001	00006	2 ba trung	66.1809	21.9767	251	gv	08888888	01	002	00040	8888	66.1809	21.9767	111.00	1		1111.00	f	\N	0.00	30000.00	1	tiêu dùng	1000.00	1800.00	12345	ab	\N	\N	\N	\N	\N	t	1	\N	\N	tấn	0.00	\N
300	2024-11-18 13:33:55.796698+00	2024-11-21 02:54:12.343408+00	\N	\N	3RZ7R755PKAL	7	ab	\N	\N	\N	22	ab	12121212	01	001	00001	ab	13.8127	-7.1436	22	gv	08888888	01	002	00040	8888	66.1809	21.9767	11.00	1		12000.00	f	\N	0.00	30000.00	1	tiêu dùng	1000.00	180000.00	12345	ab	\N	\N	\N	\N	\N	t	1	\N	20000.00	tấn	4929535.10	\N
354	2024-11-20 09:35:36.176985+00	2024-11-20 09:35:36.176985+00	\N	\N	SM69K7QLFNA7	760	linh siêu nhân	59	444.00	222.00	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	2.00	1		1111.00	f	\N	0.00	30000.00	139	rác bịch	10000.00	20000.00	hkn	98899	\N	\N	\N	\N	\N	t	1	\N	\N	túi	65575.80	\N
330	2024-11-19 09:15:06.25273+00	2024-11-20 03:33:53.047111+00	\N	\N	JOHUWJJGDLBO	640	Bao AE	\N	\N	\N	455	Bao B	0984736251	02	027	00778	Binh tan 456	10.257381823872283	106.88753744246766	455	Bao A	098765463	02	027	00778	34 an lac	10.597808625303523	106.51728802735788	11.00	1		1.00	t	\N	0.00	30000.00	20	tiêu dùng	8000000.00	270000000.00	hknko	19389183813	\N	\N	\N	\N	\N	t	1	\N	\N	cái	50923.90	\N
312	2024-11-19 07:25:27.986421+00	2024-11-19 07:25:27.986421+00	\N	\N	XDEDLF5XGASO	640	Bao AE	\N	\N	\N	454	Bao A	098765463	02	027	00778	34 an lac	10.597808625303523	106.51728802735788	455	Bao B	0984736251	02	027	00778	Binh tan 456	10.257381823872283	106.88753744246766	11.00	1		1111.00	t	\N	0.00	30000.00	25	xi than	79999900.00	879998900.00	hknko	19389183813	\N	\N	\N	\N	\N	t	1	\N	\N	khoi	50923.90	\N
353	2024-11-20 09:34:03.852073+00	2024-11-20 09:34:03.852073+00	\N	\N	DYYW4EH3PEB6	760	linh siêu nhân	\N	\N	\N	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	10.00	1		1111.00	f	\N	0.00	30000.00	139	rác bịch	10000.00	100000.00	hkn	98899	\N	\N	\N	\N	\N	t	1	\N	\N	túi	65575.80	\N
659	2024-11-21 09:43:59.226112+00	2024-11-21 09:44:20.54496+00	\N	khách hàng mua tro	P7TP1VZ6XCSB	895	khách hàng mua tro	\N	0.00	NaN	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	652	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	50.00	3	\N	\N	f	0.00	0.00	30000.00	174	tro	1000.00	50000.00	hkn	6858856	\N	\N	\N	\N	\N	t	2	0.00	NaN	tấn	\N	\N
692	2024-11-25 09:16:23.19003+00	2024-11-26 07:55:28.058087+00	\N	\N	01Q7LE6VHCMF	760	linh siêu nhân	60	1000.00	20000.00	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	10.00	11		1000.00	f	\N	0.00	102000.00	139	rác bịch	10000.00	100000.00	hkn	98899	57	bao moi	259	50H-12564	\N	f	1	\N	1000.00	túi	65524.40	10.00
694	2024-11-25 09:48:43.350259+00	2024-11-27 02:12:40.585175+00	\N	\N	URFZ3AWPJDI6	760	linh siêu nhân	60	1000.00	20000.00	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	10.00	11		1000.00	f	\N	0.00	102000.00	139	rác bịch	10000.00	100000.00	hkn	98899	57	bao moi	259	50H-12564	\N	f	1	\N	1000.00	túi	65524.40	10.00
699	2024-11-26 04:41:48.917842+00	2024-11-28 02:39:23.966847+00	\N	khách hàng mua tro	6QSHS19JAIDA	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	50.00	4	\N	\N	f	0.00	0.00	70000.00	174	tro	1000.00	50000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	120.00	10000.00	tấn	89827.80	60.00
747	2024-12-01 04:51:23.451075+00	2024-12-01 12:15:25.573883+00	\N	\N	GWLMZXQ6PRXE	899	kh bug	97	12000.00	500000.00	661	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	662	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	1.00	3		1111.00	f	\N	\N	5013111.00	180	bug	5000000.00	615000000.00	bug tnhh	3829083209	175	nh30	435	60h77890	\N	f	1	\N	12000.00	loi	99100.20	\N
743	2024-12-01 01:48:27.268651+00	2024-12-01 02:09:05.089051+00	\N	KH 100	UTZ27O42GTXC	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	111.00	3	\N	\N	f	0.00	0.00	636000.00	178	túi rác	1000.00	111000.00	hkn	868589	\N	\N	\N	\N	\N	f	2	0.00	25000.00	túi	136971.10	\N
714	2024-11-28 02:43:14.031048+00	2024-11-28 03:50:34.711608+00	\N	khách hàng mua tro	76RLWVZ69NAI	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	11	\N	\N	f	0.00	0.00	150000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	100.00	10000.00	tấn	89827.80	100.00
726	2024-11-28 09:03:32.336366+00	2024-11-28 09:08:30.199923+00	\N	khách hàng mua tro	0305O9HA1772	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	11	\N	\N	f	0.00	0.00	140000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	100.00	10000.00	tấn	89827.80	100.00
700	2024-11-26 06:27:18.993101+00	2024-11-26 10:27:07.043441+00	\N	\N	8I3VUUHTZ6AW	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	50.00	11		10000.00	f	\N	0.00	2020000.00	174	tro	40000.00	2000000.00	hkn	6858856	172	nh27	432	60h4576	\N	f	1	\N	10000.00	tấn	89827.80	50.00
701	2024-11-26 07:20:15.233622+00	2024-11-27 02:04:50.419052+00	\N	\N	8G2C4N1QMEFS	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	50.00	11		1000.00	f	\N	0.00	2011000.00	174	tro	40000.00	2000000.00	hkn	6858856	173	nh28	433	60h6784	\N	f	1	\N	10000.00	tấn	89827.80	50.00
744	2024-12-01 03:32:57.902082+00	2024-12-01 04:00:27.803337+00	\N	kh bug	QKIN1Y57P06O	899	kh bug	97	12000.00	500000.00	661	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	662	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	123.00	11	\N	\N	t	10.00	12300.00	647300.00	180	bug	1000.00	123000.00	bug tnhh	3829083209	\N	\N	\N	\N	\N	f	2	100.81	12000.00	loi	99100.20	124.00
727	2024-11-29 02:07:35.416375+00	2024-11-29 03:27:45.611445+00	\N	khách hàng mua tro	I7RFPABR4VYU	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	100.00	11	\N	\N	f	0.00	0.00	140000.00	174	tro	1000.00	100000.00	hkn	6858856	\N	\N	\N	\N	\N	f	2	100.00	10000.00	tấn	89827.80	100.00
729	2024-11-29 03:58:47.938843+00	2024-11-29 04:19:32.174678+00	\N	\N	S9P33I44GLB8	895	khách hàng mua tro	\N	\N	\N	652	linh	0869686656	10	080	02641	bjsje	11.021318611577197	107.05731493903178	652	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	40.00	11		100.00	f	\N	\N	7359611.28	174	tro	90000.00	4000000.00	hkn	6858856	139	nh8	414	40h5794	\N	t	1	\N	3759511.28	tấn	89827.80	40.00
728	2024-11-29 03:29:46.712354+00	2024-11-29 03:29:56.559309+00	\N	\N	3EI4XSFKJGL7	760	linh siêu nhân	60	1000.00	20000.00	480	aaa	0897645213	01	001	00001	ưkwkw	10.167636436441432	106.4849356897264	479	linh	08968686858	08	074	02383	dfg	10.314528917218022	106.57031210713733	40.00	3		1000.00	f	\N	\N	402000.00	139	rác bịch	10000.00	400000.00	hkn	98899	56	zdd	258	59h999	\N	f	1	\N	1000.00	túi	65524.40	\N
730	2024-11-29 04:31:22.452413+00	2024-11-29 04:33:20.441974+00	\N	\N	63T29AFVNR8J	895	khách hàng mua tro	94	10000.00	10000.00	651	hân	0896868668	10	085	02851	hsjs	10.574650456255721	107.02000736616122	653	hkn1	0965823546	79	769	27112	14 đường 100	10.565025801805463	106.60499131676464	40.00	1		1000.00	t	\N	\N	\N	174	tro	80000.00	3200000.00	hkn	6858856	\N	\N	\N	\N	\N	t	1	\N	10000.00	tấn	89827.80	\N
751	2024-12-01 05:54:31.844817+00	2024-12-01 08:27:54.007518+00	\N	kh bug	BQB5TRV6QMMV	899	kh bug	97	12000.00	500000.00	661	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	662	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	123.00	11	\N	\N	f	0.00	0.00	2135000.00	180	bug	1000.00	123000.00	bug tnhh	3829083209	\N	\N	\N	\N	\N	f	2	100.00	12000.00	loi	99100.20	123.00
757	2024-12-02 03:01:07.565428+00	2024-12-02 03:13:47.147305+00	\N	\N	ICWQ4BJK8ZMP	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	50.00	11		100.00	f	\N	\N	5025100.00	178	túi rác	100000.00	5000000.00	hkn	868589	163	nh22	423	60h3489	\N	f	1	\N	25000.00	túi	136971.10	50.00
745	2024-12-01 04:20:35.919787+00	2024-12-02 00:44:05.811802+00	\N	\N	3XJQ0CEK29VK	899	kh bug	97	12000.00	500000.00	661	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	662	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	11.00	5		1111.00	f	\N	\N	55013111.00	180	bug	5000000.00	55000000.00	bug tnhh	3829083209	180	bao test	440	27H-99990	\N	f	1	\N	12000.00	loi	99100.20	11.00
758	2024-12-02 03:03:45.731117+00	2024-12-02 03:35:53.351161+00	\N	kh bug	MCGU27DV5R5Z	899	kh bug	97	12000.00	500000.00	661	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	662	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	123.00	11	\N	\N	t	10.00	61500000.00	678512000.00	180	bug	5000000.00	615000000.00	bug tnhh	3829083209	\N	\N	\N	\N	\N	f	2	109.76	12000.00	loi	99100.20	135.00
759	2024-12-02 03:37:27.397652+00	2024-12-02 04:01:25.41608+00	\N	kh bug	S07JTIWK90ZU	899	kh bug	97	12000.00	500000.00	661	cty bug	09877648376	01	002	00040	so 20	10.710528149070072	106.40619212463031	662	kh dev	0293029302	02	027	00778	so00	10.775441499555333	107.08830113058202	123.00	11	\N	\N	t	10.00	61500000.00	678512000.00	180	bug	5000000.00	615000000.00	bug tnhh	3829083209	\N	\N	\N	\N	\N	f	2	101.93	12000.00	loi	99100.20	124.00
760	2024-12-02 03:40:50.080109+00	2024-12-02 03:45:23.954894+00	\N	\N	0FT8BSGM3QX5	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	50.00	5		1000.00	f	\N	\N	5026000.00	178	túi rác	100000.00	5000000.00	hkn	868589	163	nh22	423	60h3489	\N	f	1	\N	25000.00	túi	136971.10	50.00
763	2024-12-02 04:19:25.957748+00	2024-12-02 04:21:28.003617+00	\N	\N	8WC7LCYUUQWY	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	50.00	5		1000.00	f	\N	\N	5026000.00	178	túi rác	100000.00	5000000.00	hkn	868589	163	nh22	423	60h3489	\N	f	1	\N	25000.00	túi	136971.10	50.00
761	2024-12-02 03:47:33.057009+00	2024-12-02 04:11:56.021013+00	\N	\N	DD1U0I29SJS0	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	50.00	5		1000.00	f	\N	\N	5026000.00	178	túi rác	100000.00	5000000.00	hkn	868589	163	nh22	423	60h3489	\N	f	1	\N	25000.00	túi	136971.10	50.00
764	2024-12-02 04:22:55.985877+00	2024-12-02 04:23:46.537415+00	\N	\N	7IJJCQMHBEXB	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	50.00	4		1000.00	f	\N	\N	5026000.00	178	túi rác	100000.00	5000000.00	hkn	868589	163	nh22	423	60h3489	\N	f	1	\N	25000.00	túi	136971.10	50.00
762	2024-12-02 04:13:23.930378+00	2024-12-02 04:17:18.049401+00	\N	\N	CAW815RYVIX3	897	KH 100	96	25000.00	500000.00	657	xbxn	0896866938	11	097	03190	hdhdh	10.376483859085395	107.23843607384622	658	khánh vũ	089696968	06	063	01981	trên núi	11.031485337960644	106.37508947646023	50.00	5		1000.00	f	\N	\N	5026000.00	178	túi rác	100000.00	5000000.00	hkn	868589	163	nh22	423	60h3489	\N	f	1	\N	25000.00	túi	136971.10	50.00
\.


--
-- Data for Name: owner_car; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.owner_car (id, created_at, updated_at, deleted_at, owner_name, birthday, cccd, date_range_cccd, place_range_cccd, owner_address, email, owner_password, phone_number, role) FROM stdin;
1	2024-04-16 00:06:24.853091+00	2024-04-16 00:06:24.853091+00	\N	Nguyễn Văn Một	1998-07-19	241966892	11-03-2016	Đồng Tháp	An Bình - Định Yên - Lấp Vò	linh1@mail.com	$2a$10$tZJoYyAXH.W.ix9ESkf6wOBiV9530px.ax7WWxIvcwflkKvZiUZ16	0898776352	admin
3	2024-04-16 00:06:24.853091+00	2024-04-16 00:06:24.853091+00	\N	Nguyễn Văn Ba	1998-07-19	141966892	11-03-2016	Đồng Tháp	An Bình - Định Yên - Lấp Vò	linh3@mail.com	$2a$10$iawoRxBefud3HessM82C7ObtUl4/73bHfCU50ekqH4FDQCWSBRFPe	0898776351	admin
2	2024-04-16 00:06:24.853091+00	2024-04-16 00:06:24.853091+00	\N	Nguyễn Văn Hai	1998-07-19	341966892	11-03-2016	Đồng Tháp	An Bình - Định Yên - Lấp Vò	linh2@mail.com	$2a$10$iawoRxBefud3HessM82C7ObtUl4/73bHfCU50ekqH4FDQCWSBRFPe	0898776353	admin
4	2024-04-16 00:06:24.853091+00	2024-04-16 00:06:24.853091+00	\N	Nguyễn Văn Bốn	1998-07-19	112111122	11-03-2016	Đồng Tháp	An Bình - Định Yên - Lấp Vò	hkn@gmail.com	$2a$10$iawoRxBefud3HessM82C7ObtUl4/73bHfCU50ekqH4FDQCWSBRFPe	0898773352	admin
5	2024-07-09 03:32:49.239961+00	2024-07-09 03:32:49.239961+00	\N	Hoa Kien Nhan	2016-28-10	20162810	2016-28-10	Ho Chi Minh	14 đường 100 - phường thạch mỹ lợi	hknadmin@gmail.com	$2a$10$iawoRxBefud3HessM82C7ObtUl4/73bHfCU50ekqH4FDQCWSBRFPe	02877703388	super_admin
\.


--
-- Data for Name: permission; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.permission (id, created_at, updated_at, deleted_at, permission_name, description, company_id) FROM stdin;
4	2024-06-07 07:04:46.857865+00	2024-06-07 07:04:46.857865+00	\N	archive_task	Quyền ẩn công việc	1
3	2024-06-07 06:53:08.927193+00	2024-06-07 06:53:08.927193+00	\N	assign_task	Quyền giao công việc	1
1	2024-06-07 06:52:17.902088+00	2024-06-07 06:52:17.902088+00	\N	create_task	Quyền tạo công việc	1
2	2024-06-07 06:52:50.344824+00	2024-06-07 06:52:50.344824+00	\N	view_task	Quyền xem công việc	1
\.


--
-- Data for Name: product_vehicle_types; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.product_vehicle_types (product_id, vehicle_type_id) FROM stdin;
20	3
20	2
3	2
4	2
4	1
1	1
6	1
24	9
25	4
58	49
91	49
125	49
126	1
134	115
135	116
136	116
137	117
138	118
139	120
140	121
141	122
174	155
175	156
176	158
177	159
178	155
179	160
180	161
181	162
\.


--
-- Data for Name: products; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.products (id, created_at, updated_at, deleted_at, name, unit, vehicle_type_id) FROM stdin;
3	2024-10-17 10:04:48.242266+00	2024-10-17 10:04:48.242266+00	\N	tro bay	tấn	2
4	2024-10-21 09:47:51.399452+00	2024-10-21 09:47:51.399452+00	\N	nhựa dẻo	tấn	2
7	2024-11-03 23:08:33.630857+00	2024-11-03 23:08:33.630857+00	\N	xe đầu kéo	kg	2
8	2024-11-05 07:15:01.570908+00	2024-11-05 07:15:01.570908+00	\N	nuoc	khoi	1
9	2024-11-08 06:47:25.553899+00	2024-11-08 06:47:25.553899+00	\N	than đá	tấn	3
11	2024-11-11 07:09:51.298419+00	2024-11-11 07:09:51.298419+00	\N	tro bay 2	khối	2
12	2024-11-11 14:22:56.750978+00	2024-11-11 14:22:56.750978+00	\N	tro bay 3	tấn	3
13	2024-11-11 15:24:50.759927+00	2024-11-11 15:24:50.759927+00	\N	tro bay 4	tấn	4
14	2024-11-11 15:24:58.703722+00	2024-11-11 15:24:58.703722+00	\N	tro bay 5	tấn	5
17	2024-11-13 09:07:43.078893+00	2024-11-13 09:07:43.078893+00	\N	tiêu dùng	khoi	2
1	2024-10-17 09:55:16.6094+00	2024-10-17 09:55:16.6094+00	\N	tiêu dùng	tấn	3
18	2024-11-13 09:09:45.452732+00	2024-11-13 09:09:45.452732+00	\N	tiêu dùng	khoi	3
16	2024-11-13 09:04:26.776286+00	2024-11-13 09:04:26.776286+00	\N	tro bay 2	khoi	5
6	2024-10-21 09:48:23.792928+00	2024-10-21 09:48:23.792928+00	\N	cát 2	khối	3
5	2024-10-21 09:48:16.037515+00	2024-10-21 09:48:16.037515+00	\N	cát 1	khối	1
20	2024-11-13 22:49:30.067748+00	2024-11-13 22:49:30.067748+00	\N	tiêu dùng	cái	\N
22	2024-11-13 23:02:21.405719+00	2024-11-13 23:02:21.405719+00	2024-11-13 23:09:32.108922+00	tiêu dùng	cái	\N
23	2024-11-13 23:02:48.102012+00	2024-11-13 23:02:48.102012+00	2024-11-13 23:09:43.080219+00	tiêu dùng	cái	\N
10	2024-11-11 07:09:34.622627+00	2024-11-11 07:09:34.622627+00	2024-11-13 23:09:32.108922+00	tro bay 1	khối	1
24	2024-11-14 07:40:55.508903+00	2024-11-14 07:40:55.508903+00	\N	xi măng	khối	\N
25	2024-11-18 07:51:42.449244+00	2024-11-18 07:51:42.449244+00	\N	xi than	khoi	\N
58	2024-11-19 04:12:23.690659+00	2024-11-19 04:12:23.690659+00	\N	tro bay 6	tấn	\N
91	2024-11-19 04:37:04.505485+00	2024-11-19 04:37:04.505485+00	\N	tro bay 8	tấn	\N
125	2024-11-19 06:39:51.870577+00	2024-11-19 06:39:51.870577+00	\N	tro bay 10	tấn	\N
126	2024-11-19 08:08:50.512078+00	2024-11-19 08:08:50.512078+00	\N	dầu	lít	1
134	2024-11-20 06:06:25.469402+00	2024-11-20 06:06:25.469402+00	\N	sắt vụn	tấn	\N
135	2024-11-20 07:01:13.934123+00	2024-11-20 07:01:13.934123+00	\N	đồng nát	kí	\N
136	2024-11-20 07:07:35.27401+00	2024-11-20 07:07:35.27401+00	\N	sắt 1	kí	\N
137	2024-11-20 07:18:22.628516+00	2024-11-20 07:18:22.628516+00	\N	sắt vụn 2	kí	\N
138	2024-11-20 08:21:33.872401+00	2024-11-20 08:21:33.872401+00	\N	nhôm	kí	\N
139	2024-11-20 08:33:10.759844+00	2024-11-20 08:33:10.759844+00	\N	rác bịch	túi	\N
140	2024-11-20 09:55:13.442614+00	2024-11-20 09:55:13.442614+00	\N	cốt thép	tấn	\N
141	2024-11-21 08:29:45.536823+00	2024-11-21 08:29:45.536823+00	\N	hộp hàng	hộp	\N
174	2024-11-21 09:38:29.179233+00	2024-11-21 09:38:29.179233+00	\N	tro	tấn	\N
175	2024-11-22 03:09:30.424676+00	2024-11-22 03:09:30.424676+00	\N	hộp nhựa	kí	\N
176	2024-11-22 04:14:31.818761+00	2024-11-22 04:14:31.818761+00	\N	bánh tráng	bịch	\N
177	2024-11-23 03:59:35.069743+00	2024-11-23 03:59:35.069743+00	\N	nón lá	cái	\N
178	2024-11-25 10:04:16.166279+00	2024-11-25 10:04:16.166279+00	\N	túi rác	túi	\N
179	2024-11-26 07:39:03.765291+00	2024-11-26 07:39:03.765291+00	\N	bún đậu mắm tôm	phần	\N
180	2024-11-30 22:05:42.452891+00	2024-11-30 22:05:42.452891+00	\N	bug	loi	\N
181	2024-12-02 04:06:32.220241+00	2024-12-02 04:06:32.220241+00	\N	hàng shopee	hộp	\N
\.


--
-- Data for Name: ratings; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.ratings (id, created_at, updated_at, deleted_at, pre_order_id, rating_score_customer, rating_comment_customer, rating_score_owner, rating_comment_owner) FROM stdin;
\.


--
-- Data for Name: role; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.role (id, created_at, updated_at, deleted_at, role_name, role_level, description, company_id) FROM stdin;
2	2024-06-07 06:23:22.999274+00	2024-06-07 06:23:22.999274+00	\N	vice_director	2	phó giám đốc	1
4	2024-06-07 06:27:52.7546+00	2024-06-07 06:27:52.7546+00	\N	head_business	3	trưởng phòng kinh doanh	1
3	2024-06-07 06:26:44.238237+00	2024-06-07 06:26:44.238237+00	\N	head_accountant	3	trưởng phòng kế toán	1
5	2024-06-07 06:46:21.25589+00	2024-06-07 06:46:21.25589+00	\N	vice_accountant	4	phó phòng kế toán	1
6	2024-06-07 06:46:41.657873+00	2024-06-07 06:46:41.657873+00	\N	vice_business	4	phó phòng kinh doanh	1
7	2024-06-07 06:47:28.757136+00	2024-06-07 06:47:28.757136+00	\N	accountant	5	nhân viên phòng kế toán	1
8	2024-06-07 06:48:50.589+00	2024-06-07 06:48:50.589+00	\N	business	5	nhân viên phòng kinh doanh	1
9	2024-06-07 07:07:03.537656+00	2024-06-07 07:07:03.537656+00	\N	international_sale_man	3	nhân viên phòng kinh doanh quốc tế	1
9999	2024-06-12 08:49:37.978849+00	2024-06-12 08:49:37.978849+00	\N	super_admin	9999	super admin	1
1	2024-06-07 06:17:31.743609+00	2024-06-07 06:17:31.743609+00	\N	director	0	giám đốc	1
13	2024-06-07 08:08:24.208265+00	2024-06-07 08:08:24.208265+00	\N	driver	7	tài xế	1
19	2024-07-01 08:57:03.063808+00	2024-07-01 08:57:03.063808+00	2024-07-02 02:35:06.388432+00	tên chức vụ 1	5		1
18	2024-07-01 08:49:55.220092+00	2024-07-01 08:49:55.220092+00	2024-07-05 04:46:04.92066+00	tên chức vụ	5		1
20	2024-07-05 04:59:32.353067+00	2024-07-05 04:59:32.353067+00	\N	tên chức vụ 7 	5		1
21	2024-07-05 05:06:00.147535+00	2024-07-05 05:06:00.147535+00	\N	tên chức vụ 77 	5		1
22	2024-07-05 05:06:33.958181+00	2024-07-05 05:06:33.958181+00	\N	tên chức vụ 777 	5	mô tả chức vụ 1	1
12	2024-06-07 08:07:53.47474+00	2024-06-07 08:07:53.47474+00	\N	manager	3	quản lý linh kiện	1
25	2024-07-08 06:29:35.063252+00	2024-07-08 06:29:35.063252+00	\N	tên chức vụ 77777 	1	mô tả chức vụ 1	1
\.


--
-- Data for Name: role_departments; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.role_departments (id, created_at, updated_at, deleted_at, role_id, department_id) FROM stdin;
1	2024-06-30 11:55:34.483403+00	2024-06-30 11:55:34.483403+00	\N	1	1
2	2024-06-30 11:55:47.294265+00	2024-06-30 11:55:47.294265+00	\N	2	1
3	2024-06-30 11:56:27.422843+00	2024-06-30 11:56:27.422843+00	\N	3	3
4	2024-06-30 11:56:50.687775+00	2024-06-30 11:56:50.687775+00	\N	4	2
5	2024-06-30 11:57:12.536549+00	2024-06-30 11:57:12.536549+00	\N	5	3
6	2024-06-30 11:57:27.931312+00	2024-06-30 11:57:27.931312+00	\N	6	2
7	2024-06-30 11:57:54.294107+00	2024-06-30 11:57:54.294107+00	\N	7	3
8	2024-06-30 11:58:05.310838+00	2024-06-30 11:58:05.310838+00	\N	8	2
9	2024-06-30 11:58:32.251384+00	2024-06-30 11:58:32.251384+00	\N	9	5
11	2024-07-01 08:57:03.073973+00	2024-07-01 08:57:03.073973+00	2024-07-02 02:35:06.396055+00	19	3
10	2024-07-01 08:49:55.228322+00	2024-07-01 08:49:55.228322+00	2024-07-05 04:46:04.930416+00	18	3
14	2024-07-05 04:59:32.366344+00	2024-07-05 04:59:32.366344+00	\N	20	3
15	2024-07-05 05:06:00.162603+00	2024-07-05 05:06:00.162603+00	\N	21	3
16	2024-07-05 05:06:33.969132+00	2024-07-05 05:06:33.969132+00	\N	22	3
17	2024-07-08 03:42:26.671327+00	2024-07-08 03:42:26.671327+00	\N	12	3
20	2024-07-08 06:29:35.075455+00	2024-07-08 06:29:35.075455+00	\N	25	3
\.


--
-- Data for Name: role_hierarchies; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.role_hierarchies (id, created_at, updated_at, deleted_at, department_id, manager_role_id, subordinate_role_id) FROM stdin;
1	2024-07-08 03:52:08.035847+00	2024-07-08 03:52:08.035847+00	\N	3	3	5
2	2024-07-08 03:52:08.035847+00	2024-07-08 03:52:08.035847+00	\N	3	5	7
3	2024-07-08 04:56:50.448632+00	2024-07-08 04:56:50.448632+00	\N	3	3	23
4	2024-07-08 06:26:56.855428+00	2024-07-08 06:26:56.855428+00	\N	3	3	24
5	2024-07-08 06:29:35.078966+00	2024-07-08 06:29:35.078966+00	\N	3	3	25
\.


--
-- Data for Name: role_permission; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.role_permission (id, created_at, updated_at, deleted_at, role_id, permission_id, company_id) FROM stdin;
1	2024-06-07 06:53:56.066977+00	2024-06-07 06:53:56.066977+00	\N	1	1	1
2	2024-06-07 06:54:17.800877+00	2024-06-07 06:54:17.800877+00	\N	1	2	1
3	2024-06-07 06:54:17.800877+00	2024-06-07 06:54:17.800877+00	\N	1	3	1
4	2024-06-07 06:55:12.134817+00	2024-06-07 06:55:12.134817+00	\N	2	1	1
5	2024-06-07 06:55:12.134817+00	2024-06-07 06:55:12.134817+00	\N	2	2	1
6	2024-06-07 06:55:12.134817+00	2024-06-07 06:55:12.134817+00	\N	2	3	1
7	2024-06-07 06:56:21.302579+00	2024-06-07 06:56:21.302579+00	\N	3	1	1
8	2024-06-07 06:56:21.302579+00	2024-06-07 06:56:21.302579+00	\N	3	2	1
9	2024-06-07 06:56:21.302579+00	2024-06-07 06:56:21.302579+00	\N	3	3	1
10	2024-06-07 06:56:57.981073+00	2024-06-07 06:56:57.981073+00	\N	4	1	1
11	2024-06-07 06:56:57.981073+00	2024-06-07 06:56:57.981073+00	\N	4	2	1
12	2024-06-07 06:56:57.981073+00	2024-06-07 06:56:57.981073+00	\N	4	3	1
15	2024-06-07 07:01:13.311715+00	2024-06-07 07:01:13.311715+00	\N	5	1	1
16	2024-06-07 07:01:13.311715+00	2024-06-07 07:01:13.311715+00	\N	5	2	1
17	2024-06-07 07:01:13.311715+00	2024-06-07 07:01:13.311715+00	\N	5	3	1
18	2024-06-07 07:01:28.012262+00	2024-06-07 07:01:28.012262+00	\N	6	1	1
19	2024-06-07 07:01:28.012262+00	2024-06-07 07:01:28.012262+00	\N	6	2	1
20	2024-06-07 07:01:28.012262+00	2024-06-07 07:01:28.012262+00	\N	6	3	1
21	2024-06-07 07:01:51.908598+00	2024-06-07 07:01:51.908598+00	\N	7	2	1
22	2024-06-07 07:01:51.908598+00	2024-06-07 07:01:51.908598+00	\N	8	2	1
23	2024-06-11 01:59:02.849264+00	2024-06-11 01:59:02.849264+00	\N	5	2	1
\.


--
-- Data for Name: task; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.task (id, created_at, updated_at, deleted_at, title, description, assigned_by, status, company_id, repeat, department_id, deadline, date_assigned, task_process) FROM stdin;
\.


--
-- Data for Name: task_process; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.task_process (id, created_at, updated_at, deleted_at, step, task_process_detail, status, task_id) FROM stdin;
\.


--
-- Data for Name: transactions; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.transactions (id, created_at, updated_at, deleted_at, internal_order_id, user_role_id, user_role, transaction_type, price_router, transaction_status, order_type) FROM stdin;
2	2024-07-29 10:10:01.100721+00	2024-07-29 10:10:01.100721+00	\N	23	7	driver	income	123456.00	pending	f
1	2024-07-29 09:22:39.748401+00	2024-07-29 09:22:39.748401+00	\N	23	5	owner	income	739398.68	pending	f
3	2024-08-13 07:16:26.678082+00	2024-08-13 07:16:26.678082+00	\N	1	7	driver	income	123456.00	pending	f
4	2024-08-15 04:46:01.543332+00	2024-08-15 04:46:01.543332+00	\N	6	5	owner	income	739398.68	pending	f
5	2024-08-16 04:08:17.584603+00	2024-08-16 04:08:17.584603+00	\N	3	1	driver	income	10000.00	pending	f
6	2024-08-16 04:08:18.695284+00	2024-08-16 04:08:18.695284+00	\N	3	0	driver	income	20000.00	pending	f
7	2024-08-16 04:29:14.097804+00	2024-08-16 04:29:14.097804+00	\N	3	1	driver	income	10000.00	pending	f
8	2024-08-16 04:45:35.383561+00	2024-08-16 04:45:35.383561+00	\N	3	1	driver	income	10000.00	pending	f
9	2024-08-16 04:45:36.483874+00	2024-08-16 04:45:36.483874+00	\N	3	3	driver	income	20000.00	pending	f
10	2024-08-16 06:18:46.930056+00	2024-08-16 06:18:46.930056+00	\N	8	5	owner	income	739398.68	pending	f
11	2024-08-16 06:53:01.559182+00	2024-08-16 06:53:01.559182+00	\N	9	5	owner	income	739398.68	pending	f
12	2024-08-16 07:11:50.760836+00	2024-08-16 07:11:50.760836+00	\N	9	70	driver	income	100000.00	pending	f
13	2024-08-16 07:20:38.63157+00	2024-08-16 07:20:38.63157+00	\N	8	70	driver	income	500.00	pending	f
14	2024-08-16 07:20:39.428529+00	2024-08-16 07:20:39.428529+00	\N	8	1	driver	income	10000.00	pending	f
15	2024-08-16 07:20:40.230265+00	2024-08-16 07:20:40.230265+00	\N	8	3	driver	income	200.00	pending	f
16	2024-08-16 07:26:36.131185+00	2024-08-16 07:26:36.131185+00	\N	8	5	driver	income	99999.00	pending	f
17	2024-08-16 09:44:22.658325+00	2024-08-16 09:44:22.658325+00	\N	10	5	owner	income	739398.68	pending	f
18	2024-08-22 10:25:48.588951+00	2024-08-22 10:25:48.588951+00	\N	12	4	driver	income	0.00	pending	f
19	2024-08-22 10:25:48.924984+00	2024-08-22 10:25:48.924984+00	\N	12	6	driver	income	0.00	pending	f
20	2024-08-22 10:25:49.24972+00	2024-08-22 10:25:49.24972+00	\N	12	46	driver	income	0.00	pending	f
21	2024-08-22 10:25:49.588683+00	2024-08-22 10:25:49.588683+00	\N	12	72	driver	income	99999.00	pending	f
22	2024-08-26 07:19:27.496138+00	2024-08-26 07:19:27.496138+00	\N	2	4	driver	income	123456.00	pending	f
31	2024-09-04 07:45:42.630501+00	2024-09-04 07:45:42.630501+00	\N	17	6	driver	income	123456.00	pending	f
25	2024-08-27 04:56:20.774981+00	2024-08-27 04:56:20.774981+00	\N	15	46	driver	income	0.00	pending	t
26	2024-08-27 04:56:21.12993+00	2024-08-27 04:56:21.12993+00	\N	15	72	driver	income	99999.00	pending	t
28	2024-08-31 06:42:22.621824+00	2024-08-31 06:42:22.621824+00	\N	18	5	driver	income	0.00	pending	t
27	2024-08-31 06:42:22.112218+00	2024-08-31 06:42:22.112218+00	\N	18	83	driver	income	0.00	pending	t
23	2024-08-27 04:56:20.068901+00	2024-08-27 04:56:20.068901+00	\N	15	4	driver	income	0.00	pending	t
24	2024-08-27 04:56:20.423394+00	2024-08-27 04:56:20.423394+00	\N	15	6	driver	income	0.00	pending	t
33	2024-09-09 03:57:05.277626+00	2024-09-09 03:57:05.277626+00	\N	19	5	owner	income	397600.00	pending	f
34	2024-09-09 04:04:16.516172+00	2024-09-09 04:04:16.516172+00	\N	20	5	owner	income	397600.00	pending	f
35	2024-09-09 04:18:06.315913+00	2024-09-09 04:18:06.315913+00	\N	20	46	driver	income	123456.00	pending	f
36	2024-09-09 04:27:06.282831+00	2024-09-09 04:27:06.282831+00	\N	20	46	driver	income	123456.00	pending	f
37	2024-09-09 04:27:06.282831+00	2024-09-09 04:27:06.282831+00	\N	22	72	driver	income	2000.00	pending	f
38	2024-09-09 04:46:26.773685+00	2024-09-09 04:46:26.773685+00	\N	20	46	driver	income	123456.00	pending	f
39	2024-09-09 08:21:04.765559+00	2024-09-09 08:21:04.765559+00	\N	19	5	driver	income	123456.00	pending	f
53	2024-09-09 16:13:14.931247+00	2024-09-09 16:13:14.931247+00	\N	35	5	owner	income	3792900.00	pending	f
54	2024-09-09 16:13:34.673014+00	2024-09-09 16:13:34.673014+00	\N	36	5	owner	income	397600.00	pending	f
55	2024-09-09 16:15:09.517618+00	2024-09-09 16:15:09.517618+00	\N	37	5	owner	income	397600.00	pending	f
56	2024-09-09 16:15:10.33082+00	2024-09-09 16:15:10.33082+00	\N	38	5	owner	income	397600.00	pending	f
57	2024-09-09 16:15:11.059453+00	2024-09-09 16:15:11.059453+00	\N	39	5	owner	income	397600.00	pending	f
58	2024-09-09 16:15:11.777379+00	2024-09-09 16:15:11.777379+00	\N	40	5	owner	income	397600.00	pending	f
59	2024-09-09 16:15:12.458908+00	2024-09-09 16:15:12.458908+00	\N	41	5	owner	income	397600.00	pending	f
60	2024-09-09 16:15:13.24395+00	2024-09-09 16:15:13.24395+00	\N	42	5	owner	income	397600.00	pending	f
61	2024-09-09 16:15:14.191089+00	2024-09-09 16:15:14.191089+00	\N	43	5	owner	income	397600.00	pending	f
62	2024-09-09 16:15:14.93264+00	2024-09-09 16:15:14.93264+00	\N	44	5	owner	income	397600.00	pending	f
63	2024-09-09 16:15:15.619564+00	2024-09-09 16:15:15.619564+00	\N	45	5	owner	income	397600.00	pending	f
64	2024-09-09 16:15:16.40745+00	2024-09-09 16:15:16.40745+00	\N	46	5	owner	income	397600.00	pending	f
65	2024-09-09 16:15:50.704296+00	2024-09-09 16:15:50.704296+00	\N	47	5	owner	income	397600.00	pending	f
66	2024-09-09 16:15:51.467581+00	2024-09-09 16:15:51.467581+00	\N	48	5	owner	income	397600.00	pending	f
67	2024-09-09 16:15:55.048612+00	2024-09-09 16:15:55.048612+00	\N	49	5	owner	income	397600.00	pending	f
68	2024-09-09 16:16:14.88504+00	2024-09-09 16:16:14.88504+00	\N	50	5	owner	income	397600.00	pending	f
69	2024-09-09 16:16:15.690324+00	2024-09-09 16:16:15.690324+00	\N	51	5	owner	income	397600.00	pending	f
70	2024-09-09 16:16:16.427888+00	2024-09-09 16:16:16.427888+00	\N	52	5	owner	income	397600.00	pending	f
71	2024-09-09 16:16:17.167607+00	2024-09-09 16:16:17.167607+00	\N	53	5	owner	income	397600.00	pending	f
72	2024-09-09 16:16:17.829989+00	2024-09-09 16:16:17.829989+00	\N	54	5	owner	income	397600.00	pending	f
73	2024-09-09 16:16:18.547337+00	2024-09-09 16:16:18.547337+00	\N	55	5	owner	income	397600.00	pending	f
74	2024-09-09 16:16:19.241789+00	2024-09-09 16:16:19.241789+00	\N	56	5	owner	income	397600.00	pending	f
32	2024-09-07 01:59:03.254765+00	2024-09-07 01:59:03.254765+00	\N	1	4	driver	income	123456.00	pending	f
29	2024-09-04 07:26:37.986975+00	2024-09-09 09:37:25.871988+00	\N	13	4	driver	income	123456.00	pending	f
30	2024-09-04 07:27:39.862524+00	2024-09-09 09:37:25.871988+00	\N	13	4	owner	income	123456.00	success	t
75	2024-09-09 16:16:19.904635+00	2024-09-09 16:16:19.904635+00	\N	57	5	owner	income	397600.00	pending	f
76	2024-09-09 16:16:20.506945+00	2024-09-09 16:16:20.506945+00	\N	58	5	owner	income	397600.00	pending	f
77	2024-09-09 16:19:01.452034+00	2024-09-09 16:19:01.452034+00	\N	59	5	owner	income	3792900.00	pending	f
78	2024-09-09 16:19:10.299332+00	2024-09-09 16:19:10.299332+00	\N	60	5	owner	income	3792900.00	pending	f
79	2024-09-09 16:19:11.076924+00	2024-09-09 16:19:11.076924+00	\N	61	5	owner	income	3792900.00	pending	f
80	2024-09-09 16:19:11.847561+00	2024-09-09 16:19:11.847561+00	\N	62	5	owner	income	3792900.00	pending	f
81	2024-09-09 16:19:12.526424+00	2024-09-09 16:19:12.526424+00	\N	63	5	owner	income	3792900.00	pending	f
82	2024-09-09 16:19:13.207446+00	2024-09-09 16:19:13.207446+00	\N	64	5	owner	income	3792900.00	pending	f
83	2024-09-09 16:19:18.393787+00	2024-09-09 16:19:18.393787+00	\N	65	5	owner	income	3792900.00	pending	f
84	2024-09-09 16:19:19.119503+00	2024-09-09 16:19:19.119503+00	\N	66	5	owner	income	3792900.00	pending	f
85	2024-09-09 16:19:19.790358+00	2024-09-09 16:19:19.790358+00	\N	67	5	owner	income	3792900.00	pending	f
86	2024-09-09 16:19:20.512656+00	2024-09-09 16:19:20.512656+00	\N	68	5	owner	income	3792900.00	pending	f
87	2024-09-09 16:19:21.193526+00	2024-09-09 16:19:21.193526+00	\N	69	5	owner	income	3792900.00	pending	f
88	2024-09-09 16:20:09.477794+00	2024-09-09 16:20:09.477794+00	\N	70	5	owner	income	3792900.00	pending	f
89	2024-09-10 04:15:50.097907+00	2024-09-10 04:15:50.097907+00	\N	71	5	owner	income	3439590.00	pending	f
91	2024-09-10 18:28:15.253224+00	2024-09-10 18:28:15.253224+00	\N	74	5	owner	income	821590.00	pending	f
92	2024-09-10 20:54:07.64473+00	2024-09-10 20:54:07.64473+00	\N	19	5	driver	income	123456.00	pending	f
93	2024-09-10 21:14:35.403905+00	2024-09-10 21:14:35.403905+00	\N	19	5	driver	income	123456.00	pending	f
94	2024-09-10 21:14:57.144488+00	2024-09-10 21:14:57.144488+00	\N	19	5	driver	income	1111.00	pending	f
95	2024-09-11 01:28:31.284253+00	2024-09-11 01:28:31.284253+00	\N	19	5	driver	income	1111.00	pending	f
96	2024-09-11 01:28:35.424227+00	2024-09-11 01:28:35.424227+00	\N	19	5	driver	income	1111.00	pending	f
97	2024-09-11 01:28:55.448656+00	2024-09-11 01:28:55.448656+00	\N	19	5	driver	income	1111.00	pending	f
98	2024-09-11 01:28:56.188192+00	2024-09-11 01:28:56.188192+00	\N	19	5	driver	income	1111.00	pending	f
99	2024-09-11 01:28:57.859754+00	2024-09-11 01:28:57.859754+00	\N	19	5	driver	income	1111.00	pending	f
100	2024-09-11 01:28:58.161732+00	2024-09-11 01:28:58.161732+00	\N	19	5	driver	income	1111.00	pending	f
101	2024-09-11 01:42:27.543052+00	2024-09-11 01:42:27.543052+00	\N	74	4	driver	income	1090.00	pending	f
102	2024-09-11 01:48:12.174861+00	2024-09-11 01:48:12.174861+00	\N	75	5	owner	income	6739590.00	pending	f
103	2024-09-11 01:50:07.080503+00	2024-09-11 01:50:07.080503+00	\N	76	5	owner	income	6739590.00	pending	f
104	2024-09-11 01:50:20.60979+00	2024-09-11 01:50:20.60979+00	\N	77	5	owner	income	6739590.00	pending	f
105	2024-09-11 01:51:48.875191+00	2024-09-11 01:51:48.875191+00	\N	78	5	owner	income	6739590.00	pending	f
106	2024-09-11 02:41:54.647993+00	2024-09-11 02:41:54.647993+00	\N	80	5	owner	income	2339590.00	pending	f
107	2024-09-11 02:43:28.66534+00	2024-09-11 02:43:28.66534+00	\N	81	5	owner	income	2339590.00	pending	f
108	2024-09-11 02:43:52.57267+00	2024-09-11 02:43:52.57267+00	\N	75	4	driver	income	10000.00	pending	f
109	2024-09-11 02:56:18.777221+00	2024-09-11 02:56:18.777221+00	\N	82	5	owner	income	2919400.00	pending	f
110	2024-09-11 02:58:43.027697+00	2024-09-11 02:58:43.027697+00	\N	82	6	driver	income	45000.00	pending	f
119	2024-09-12 06:26:06.27936+00	2024-09-12 06:26:06.27936+00	\N	83	46	driver	income	5000.00	pending	t
120	2024-09-12 06:26:06.600337+00	2024-09-12 06:26:06.600337+00	\N	83	83	driver	income	5000.00	pending	t
121	2024-09-12 06:26:06.923908+00	2024-09-12 06:26:06.923908+00	\N	83	70	driver	income	5000.00	pending	t
122	2024-09-12 06:26:07.246859+00	2024-09-12 06:26:07.246859+00	\N	83	5	driver	income	5000.00	pending	t
123	2024-09-12 07:08:37.026608+00	2024-09-12 07:08:37.026608+00	\N	84	70	driver	income	5000.00	pending	t
124	2024-09-12 07:08:37.387788+00	2024-09-12 07:08:37.387788+00	\N	84	83	driver	income	5000.00	pending	t
125	2024-10-29 10:20:06.404338+00	2024-10-29 10:20:06.404338+00	\N	12	4	driver	income	884519.87	pending	f
129	2024-10-30 04:10:08.824923+00	2024-10-30 04:10:08.824923+00	\N	13	6	driver	income	1000.00	pending	t
130	2024-10-30 04:10:08.938825+00	2024-10-30 04:10:08.938825+00	\N	13	7	driver	income	1000.00	pending	t
131	2024-10-30 04:10:09.055194+00	2024-10-30 04:10:09.055194+00	\N	13	8	driver	income	1000.00	pending	t
132	2024-10-31 03:56:22.790245+00	2024-10-31 03:56:22.790245+00	\N	60	4	driver	income	911517.15	pending	f
133	2024-10-31 04:00:45.043995+00	2024-10-31 04:00:45.043995+00	\N	60	4	driver	income	1393325.55	pending	f
134	2024-10-31 04:07:46.214984+00	2024-10-31 04:07:46.214984+00	\N	60	4	driver	income	911517.15	pending	f
135	2024-10-31 04:30:59.19928+00	2024-10-31 04:30:59.19928+00	\N	60	4	driver	income	1393325.55	pending	f
136	2024-10-31 04:36:46.115138+00	2024-10-31 04:36:46.115138+00	\N	62	4	driver	income	1393325.55	pending	f
137	2024-10-31 04:40:02.455039+00	2024-10-31 04:40:02.455039+00	\N	63	4	driver	income	1393325.55	pending	f
138	2024-10-31 04:47:46.520936+00	2024-10-31 04:47:46.520936+00	\N	64	4	driver	income	1393325.55	pending	f
139	2024-10-31 04:49:50.545163+00	2024-10-31 04:49:50.545163+00	\N	65	4	driver	income	1393325.55	pending	f
140	2024-10-31 04:50:34.298683+00	2024-10-31 04:50:34.298683+00	\N	66	4	driver	income	1393325.55	pending	f
141	2024-10-31 04:52:23.575424+00	2024-10-31 04:52:23.575424+00	\N	67	4	driver	income	1393325.55	pending	f
142	2024-10-31 04:55:05.624782+00	2024-10-31 04:55:05.624782+00	\N	68	4	driver	income	1393325.55	pending	f
143	2024-10-31 08:39:46.693131+00	2024-10-31 08:39:46.693131+00	\N	70	4	driver	income	1000.00	pending	f
144	2024-10-31 08:42:55.412441+00	2024-10-31 08:42:55.412441+00	\N	72	4	driver	income	1000.00	pending	f
145	2024-10-31 08:49:52.998359+00	2024-10-31 08:49:52.998359+00	\N	73	4	driver	income	1000.00	pending	f
146	2024-10-31 09:18:23.216509+00	2024-10-31 09:18:23.216509+00	\N	75	4	driver	income	1000000.00	pending	f
147	2024-10-31 09:23:19.598725+00	2024-10-31 09:23:19.598725+00	\N	76	4	driver	income	911517.15	pending	f
148	2024-10-31 09:40:25.519848+00	2024-10-31 09:40:25.519848+00	\N	77	4	driver	income	0.00	pending	f
149	2024-10-31 09:45:52.230074+00	2024-10-31 09:45:52.230074+00	\N	77	4	driver	income	911517.15	pending	f
150	2024-10-31 10:16:10.850074+00	2024-10-31 10:16:10.850074+00	\N	78	4	driver	income	911517.15	pending	f
151	2024-11-01 02:41:45.025421+00	2024-11-01 02:41:45.025421+00	\N	79	4	driver	income	500000.00	pending	f
152	2024-11-01 02:45:20.391852+00	2024-11-01 02:45:20.391852+00	\N	80	4	driver	income	500000.00	pending	f
153	2024-11-01 02:48:23.685486+00	2024-11-01 02:48:23.685486+00	\N	82	4	driver	income	1393325.55	pending	f
154	2024-11-01 03:00:15.135569+00	2024-11-01 03:00:15.135569+00	\N	83	4	driver	income	1393325.55	pending	f
155	2024-11-01 03:01:30.350629+00	2024-11-01 03:01:30.350629+00	\N	84	4	driver	income	1393325.55	pending	f
156	2024-11-01 03:16:55.480775+00	2024-11-01 03:16:55.480775+00	\N	85	4	driver	income	1393325.55	pending	f
157	2024-11-01 03:20:45.256795+00	2024-11-01 03:20:45.256795+00	\N	86	4	driver	income	911517.15	pending	f
158	2024-11-01 03:22:27.50639+00	2024-11-01 03:22:27.50639+00	\N	87	4	driver	income	911517.15	pending	f
159	2024-11-01 09:05:14.661352+00	2024-11-01 09:05:14.661352+00	\N	88	4	driver	income	500000.00	pending	f
160	2024-11-01 09:06:42.138115+00	2024-11-01 09:06:42.138115+00	\N	89	4	driver	income	500000.00	pending	f
161	2024-11-01 09:07:24.481017+00	2024-11-01 09:07:24.481017+00	\N	90	4	driver	income	500000.00	pending	f
162	2024-11-02 04:01:46.079838+00	2024-11-02 04:01:46.079838+00	\N	92	4	driver	income	500000.00	pending	f
163	2024-11-02 04:30:47.442991+00	2024-11-02 04:30:47.442991+00	\N	93	4	driver	income	500000.00	pending	f
164	2024-11-02 04:34:38.294008+00	2024-11-02 04:34:38.294008+00	\N	94	4	driver	income	500000.00	pending	f
165	2024-11-02 04:36:53.680955+00	2024-11-02 04:36:53.680955+00	\N	95	4	driver	income	500000.00	pending	f
166	2024-11-02 04:51:10.848451+00	2024-11-02 04:51:10.848451+00	\N	96	4	driver	income	500000.00	pending	f
167	2024-11-03 05:06:09.986263+00	2024-11-03 05:06:09.986263+00	\N	97	4	driver	income	500000.00	pending	f
168	2024-11-03 05:33:21.150108+00	2024-11-03 05:33:21.150108+00	\N	98	4	driver	income	500000.00	pending	f
170	2024-11-04 03:20:06.1592+00	2024-11-04 03:20:06.1592+00	\N	111	6	driver	income	700000.00	pending	t
171	2024-11-04 03:20:06.249144+00	2024-11-04 03:20:06.249144+00	\N	111	7	driver	income	700000.00	pending	t
172	2024-11-04 03:20:06.339137+00	2024-11-04 03:20:06.339137+00	\N	111	8	driver	income	700000.00	pending	t
173	2024-11-04 03:27:43.26811+00	2024-11-04 03:27:43.26811+00	\N	113	6	driver	income	450000.00	pending	t
174	2024-11-04 03:27:43.355056+00	2024-11-04 03:27:43.355056+00	\N	113	7	driver	income	450000.00	pending	t
175	2024-11-04 03:27:43.472316+00	2024-11-04 03:27:43.472316+00	\N	113	8	driver	income	450000.00	pending	t
176	2024-11-04 03:33:35.458133+00	2024-11-04 03:33:35.458133+00	\N	114	6	driver	income	450000.00	pending	t
177	2024-11-04 03:33:40.730054+00	2024-11-04 03:33:40.730054+00	\N	114	7	driver	income	450000.00	pending	t
178	2024-11-04 03:33:45.451668+00	2024-11-04 03:33:45.451668+00	\N	114	8	driver	income	450000.00	pending	t
180	2024-11-04 03:50:40.778655+00	2024-11-04 03:50:40.778655+00	\N	116	6	driver	income	98052.24	pending	t
181	2024-11-04 03:50:40.873327+00	2024-11-04 03:50:40.873327+00	\N	116	7	driver	income	98052.24	pending	t
182	2024-11-04 03:50:40.96765+00	2024-11-04 03:50:40.96765+00	\N	116	8	driver	income	98052.24	pending	t
183	2024-11-04 03:52:44.983834+00	2024-11-04 03:52:44.983834+00	\N	117	6	driver	income	250000.00	pending	t
184	2024-11-04 03:52:45.070691+00	2024-11-04 03:52:45.070691+00	\N	117	7	driver	income	250000.00	pending	t
185	2024-11-04 03:52:45.160916+00	2024-11-04 03:52:45.160916+00	\N	117	8	driver	income	250000.00	pending	t
169	2024-11-03 07:55:17.198023+00	2024-11-04 08:13:16.286978+00	\N	100	4	driver	income	1000.00	cancel	f
323	2024-11-21 06:32:55.128598+00	2024-11-21 06:32:55.128598+00	\N	524	57	driver	income	20000.00	pending	f
186	2024-11-08 01:56:30.354498+00	2024-11-08 01:56:30.354498+00	\N	121	6	driver	income	0.00	pending	t
187	2024-11-08 01:56:30.457359+00	2024-11-08 01:56:30.457359+00	\N	121	7	driver	income	0.00	pending	t
188	2024-11-08 01:56:30.800945+00	2024-11-08 01:56:30.800945+00	\N	121	8	driver	income	0.00	pending	t
189	2024-11-08 02:00:59.725955+00	2024-11-08 02:00:59.725955+00	\N	122	4	driver	income	0.00	pending	t
190	2024-11-08 02:00:59.728961+00	2024-11-08 02:00:59.728961+00	\N	122	5	driver	income	0.00	pending	t
191	2024-11-08 06:30:58.913284+00	2024-11-08 06:30:58.913284+00	\N	120	4	driver	income	123000.00	pending	f
192	2024-11-08 06:53:54.255924+00	2024-11-08 06:53:54.255924+00	\N	119	7	driver	income	123000.00	pending	f
193	2024-11-08 06:56:11.476805+00	2024-11-08 06:56:11.476805+00	\N	124	4	driver	income	0.00	pending	t
194	2024-11-08 06:56:11.479307+00	2024-11-08 06:56:11.479307+00	\N	124	5	driver	income	0.00	pending	t
195	2024-11-08 06:56:11.485014+00	2024-11-08 06:56:11.485014+00	\N	124	6	driver	income	0.00	pending	t
90	2024-09-10 18:12:52.942589+00	2024-09-10 18:12:52.942589+00	\N	72	5	owner	income	2828100.00	pending	f
356	2024-11-21 06:35:15.505074+00	2024-11-21 06:35:15.505074+00	\N	557	58	driver	income	1274401.44	pending	t
179	2024-11-04 03:45:59.915968+00	2024-11-04 08:24:41.600542+00	\N	115	4	owner	income	500000.00	success	f
196	2024-11-14 03:36:05.985547+00	2024-11-14 03:36:05.985547+00	\N	138	3	driver	income	515468.81	pending	f
197	2024-11-18 07:33:26.66143+00	2024-11-18 07:33:26.66143+00	\N	161	9	driver	income	30000.00	pending	f
230	2024-11-18 08:06:21.99591+00	2024-11-18 08:06:21.99591+00	\N	165	4	driver	income	30000.00	pending	f
231	2024-11-18 08:06:49.967793+00	2024-11-18 08:06:49.967793+00	\N	234	3	driver	income	500000.00	pending	t
232	2024-11-18 08:06:49.971164+00	2024-11-18 08:06:49.971164+00	\N	234	5	driver	income	500000.00	pending	t
233	2024-11-18 08:06:49.973818+00	2024-11-18 08:06:49.973818+00	\N	234	6	driver	income	500000.00	pending	t
234	2024-11-18 08:06:49.976362+00	2024-11-18 08:06:49.976362+00	\N	234	7	driver	income	500000.00	pending	t
263	2024-11-18 13:27:30.621694+00	2024-11-18 13:27:30.621694+00	\N	166	3	driver	income	500000.00	pending	t
264	2024-11-18 13:27:30.626479+00	2024-11-18 13:27:30.626479+00	\N	166	5	driver	income	500000.00	pending	t
265	2024-11-18 14:44:20.618377+00	2024-11-18 14:44:20.618377+00	\N	308	6	driver	income	30000.00	pending	t
266	2024-11-18 14:44:20.623559+00	2024-11-18 14:44:20.623559+00	\N	308	7	driver	income	30000.00	pending	t
267	2024-11-18 14:45:22.742966+00	2024-11-18 14:45:22.742966+00	\N	306	6	driver	income	0.00	pending	t
268	2024-11-18 14:45:22.746683+00	2024-11-18 14:45:22.746683+00	\N	306	7	driver	income	0.00	pending	t
269	2024-11-19 07:35:08.551419+00	2024-11-19 07:35:08.551419+00	\N	313	13	driver	income	705021.78	pending	f
270	2024-11-19 07:43:33.230796+00	2024-11-19 07:43:33.230796+00	\N	315	14	driver	income	14935654.06	pending	f
271	2024-11-19 07:48:35.749907+00	2024-11-19 07:48:35.749907+00	\N	314	8	driver	income	3360000.00	pending	f
272	2024-11-19 08:31:48.594493+00	2024-11-19 08:31:48.594493+00	\N	320	16	driver	income	661742.60	pending	f
273	2024-11-19 08:37:33.694958+00	2024-11-19 08:37:33.694958+00	\N	321	17	driver	income	1000.00	pending	f
274	2024-11-19 08:49:21.786704+00	2024-11-19 08:49:21.786704+00	\N	323	20	driver	income	643551.12	pending	f
275	2024-11-19 08:52:12.611546+00	2024-11-19 08:52:12.611546+00	\N	324	20	driver	income	643551.12	pending	f
277	2024-11-19 09:01:02.453592+00	2024-11-19 09:01:02.453592+00	\N	327	22	driver	income	370535.10	pending	t
278	2024-11-19 09:10:03.154339+00	2024-11-19 09:10:03.154339+00	\N	328	24	driver	income	370535.10	pending	t
279	2024-11-20 03:55:43.827054+00	2024-11-20 03:55:43.827054+00	\N	325	21	driver	income	661742.60	pending	f
280	2024-11-20 06:33:49.562216+00	2024-11-20 06:33:49.562216+00	\N	334	23	driver	income	1000.00	pending	t
281	2024-11-20 06:37:02.943475+00	2024-11-20 06:37:02.943475+00	\N	335	25	driver	income	1000.00	pending	t
282	2024-11-20 06:40:16.969799+00	2024-11-20 06:40:16.969799+00	\N	336	15	driver	income	386867.52	pending	t
283	2024-11-20 06:40:16.973255+00	2024-11-20 06:40:16.973255+00	\N	336	18	driver	income	386867.52	pending	t
284	2024-11-20 09:02:58.335923+00	2024-11-20 09:02:58.335923+00	\N	345	56	driver	income	222.00	pending	t
285	2024-11-20 09:38:46.410693+00	2024-11-20 09:38:46.410693+00	\N	350	58	driver	income	98052.24	pending	t
286	2024-11-20 09:46:10.830314+00	2024-11-20 09:46:10.830314+00	\N	356	56	driver	income	1269843.12	pending	t
287	2024-11-20 09:49:23.377298+00	2024-11-20 09:49:23.377298+00	\N	388	56	driver	income	511491.24	pending	t
288	2024-11-20 09:56:40.38782+00	2024-11-20 09:56:40.38782+00	\N	349	57	driver	income	813014.89	pending	f
289	2024-11-20 10:03:06.738042+00	2024-11-20 10:03:06.738042+00	\N	390	56	driver	income	1062035.23	pending	f
290	2024-11-21 06:23:40.136772+00	2024-11-21 06:23:40.136772+00	\N	458	56	driver	income	849042.46	pending	f
389	2024-11-21 06:43:16.308772+00	2024-11-21 06:43:16.308772+00	\N	590	59	driver	income	1000.00	pending	t
422	2024-11-21 06:45:30.094599+00	2024-11-21 06:45:30.094599+00	\N	623	61	driver	income	98052.24	pending	t
423	2024-11-21 06:45:30.100759+00	2024-11-21 06:45:30.100759+00	\N	623	94	driver	income	98052.24	pending	t
455	2024-11-21 10:08:45.449237+00	2024-11-21 10:08:45.449237+00	\N	661	131	driver	income	548825.94	pending	t
456	2024-11-21 10:08:45.574431+00	2024-11-21 10:08:45.574431+00	\N	661	132	driver	income	548825.94	pending	t
457	2024-11-22 07:34:12.270389+00	2024-11-22 07:34:12.270389+00	\N	662	137	driver	income	548825.94	pending	t
458	2024-11-22 07:34:12.397164+00	2024-11-22 07:34:12.397164+00	\N	662	138	driver	income	548825.94	pending	t
459	2024-11-22 07:47:14.927572+00	2024-11-22 07:47:14.927572+00	\N	664	137	driver	income	98052.24	pending	t
460	2024-11-22 07:47:15.058658+00	2024-11-22 07:47:15.058658+00	\N	664	138	driver	income	98052.24	pending	t
461	2024-11-22 07:57:27.786843+00	2024-11-22 07:57:27.786843+00	\N	666	139	driver	income	548825.94	pending	t
462	2024-11-22 07:57:27.91245+00	2024-11-22 07:57:27.91245+00	\N	666	140	driver	income	548825.94	pending	t
463	2024-11-22 08:02:00.436076+00	2024-11-22 08:02:00.436076+00	\N	667	56	driver	income	511491.24	pending	t
464	2024-11-22 08:10:29.732948+00	2024-11-22 08:10:29.732948+00	\N	668	141	driver	income	548825.94	pending	t
465	2024-11-22 08:10:29.856643+00	2024-11-22 08:10:29.856643+00	\N	668	142	driver	income	548825.94	pending	t
466	2024-11-22 08:16:27.530892+00	2024-11-22 08:16:27.530892+00	\N	669	141	driver	income	548825.94	pending	t
467	2024-11-22 08:16:27.65651+00	2024-11-22 08:16:27.65651+00	\N	669	142	driver	income	548825.94	pending	t
468	2024-11-22 08:24:51.297324+00	2024-11-22 08:24:51.297324+00	\N	670	143	driver	income	548825.94	pending	t
469	2024-11-22 08:24:51.422657+00	2024-11-22 08:24:51.422657+00	\N	670	144	driver	income	548825.94	pending	t
470	2024-11-22 08:29:10.983159+00	2024-11-22 08:29:10.983159+00	\N	671	143	driver	income	347635.86	pending	t
471	2024-11-22 08:29:11.108253+00	2024-11-22 08:29:11.108253+00	\N	671	144	driver	income	347635.86	pending	t
472	2024-11-22 08:32:35.121247+00	2024-11-22 08:32:35.121247+00	\N	672	139	driver	income	548825.94	pending	t
473	2024-11-22 08:32:35.246476+00	2024-11-22 08:32:35.246476+00	\N	672	140	driver	income	548825.94	pending	t
474	2024-11-22 09:21:53.445069+00	2024-11-22 09:21:53.445069+00	\N	673	145	driver	income	347635.86	pending	t
475	2024-11-22 09:21:53.571786+00	2024-11-22 09:21:53.571786+00	\N	673	146	driver	income	347635.86	pending	t
476	2024-11-22 09:40:50.854484+00	2024-11-22 09:40:50.854484+00	\N	674	147	driver	income	680812.86	pending	t
477	2024-11-22 09:40:50.978416+00	2024-11-22 09:40:50.978416+00	\N	674	148	driver	income	680812.86	pending	t
478	2024-11-23 04:05:12.111631+00	2024-11-23 04:05:12.111631+00	\N	677	150	driver	income	985223.98	pending	f
479	2024-11-25 04:27:40.562607+00	2024-11-25 04:27:40.562607+00	\N	680	164	driver	income	700656.84	pending	t
480	2024-11-25 04:27:40.687754+00	2024-11-25 04:27:40.687754+00	\N	680	165	driver	income	700656.84	pending	t
481	2024-11-25 06:32:42.566609+00	2024-11-25 06:32:42.566609+00	\N	681	57	driver	income	20000.00	pending	f
482	2024-11-25 06:56:47.534342+00	2024-11-25 06:56:47.534342+00	\N	682	164	driver	income	10000.00	pending	t
483	2024-11-25 06:56:47.659957+00	2024-11-25 06:56:47.659957+00	\N	682	165	driver	income	10000.00	pending	t
484	2024-11-25 07:18:02.466244+00	2024-11-25 07:18:02.466244+00	\N	683	164	driver	income	10000.00	pending	t
485	2024-11-25 07:18:02.59237+00	2024-11-25 07:18:02.59237+00	\N	683	165	driver	income	10000.00	pending	t
486	2024-11-25 08:07:53.303133+00	2024-11-25 08:07:53.303133+00	\N	684	163	driver	income	10000.00	pending	t
487	2024-11-25 08:07:53.428889+00	2024-11-25 08:07:53.428889+00	\N	684	166	driver	income	10000.00	pending	t
493	2024-11-25 21:13:17.287389+00	2024-11-25 21:13:17.287389+00	\N	697	57	driver	income	1010699.66	pending	t
494	2024-11-26 04:42:01.022982+00	2024-11-26 04:42:01.022982+00	\N	699	163	driver	income	10000.00	pending	t
495	2024-11-26 04:42:01.148111+00	2024-11-26 04:42:01.148111+00	\N	699	166	driver	income	10000.00	pending	t
490	2024-11-25 09:23:27.187995+00	2024-11-26 07:47:35.585615+00	\N	693	163	driver	income	10000.00	success	f
488	2024-11-25 08:37:41.830174+00	2024-11-26 07:51:20.720155+00	\N	689	57	driver	income	20000.00	success	f
498	2024-11-26 07:53:43.665718+00	2024-11-26 07:53:43.665718+00	\N	702	175	driver	income	861631.68	pending	t
499	2024-11-26 07:53:43.791586+00	2024-11-26 07:53:43.791586+00	\N	702	176	driver	income	861631.68	pending	t
489	2024-11-25 09:16:28.960019+00	2024-11-26 07:55:27.932932+00	\N	692	57	driver	income	20000.00	success	f
500	2024-11-26 08:09:25.712791+00	2024-11-26 08:09:25.712791+00	\N	704	57	driver	income	500000.00	pending	f
496	2024-11-26 06:28:24.723379+00	2024-11-26 08:12:53.35958+00	\N	700	172	driver	income	10000.00	success	f
492	2024-11-25 10:07:58.243096+00	2024-11-26 08:18:13.517795+00	\N	696	163	driver	income	947490.01	success	f
276	2024-11-19 08:55:40.044058+00	2024-11-26 10:12:03.663329+00	\N	326	19	driver	income	661742.60	success	f
497	2024-11-26 07:21:34.223187+00	2024-11-27 02:03:29.719054+00	\N	701	173	driver	income	10000.00	success	f
491	2024-11-25 09:48:51.908905+00	2024-11-27 02:10:36.184263+00	\N	694	57	driver	income	20000.00	success	f
501	2024-11-27 02:34:17.679835+00	2024-11-27 02:45:51.540201+00	\N	706	172	driver	income	500000.00	success	f
502	2024-11-27 03:09:48.221073+00	2024-11-27 03:11:19.930125+00	\N	707	172	driver	income	500000.00	success	f
503	2024-11-27 04:27:03.353203+00	2024-11-27 04:27:03.353203+00	\N	313	60	driver	income	705021.78	pending	f
504	2024-11-27 06:37:39.077579+00	2024-11-27 06:37:39.077579+00	\N	708	172	driver	income	10000.00	pending	t
505	2024-11-27 06:37:39.202245+00	2024-11-27 06:37:39.202245+00	\N	708	173	driver	income	10000.00	pending	t
506	2024-11-27 07:12:14.460049+00	2024-11-27 07:12:14.460049+00	\N	709	164	driver	income	10000.00	pending	t
507	2024-11-27 07:12:14.583576+00	2024-11-27 07:12:14.583576+00	\N	709	165	driver	income	10000.00	pending	t
508	2024-11-27 07:47:14.972726+00	2024-11-27 07:47:14.972726+00	\N	710	164	driver	income	10000.00	pending	t
509	2024-11-27 07:47:15.09791+00	2024-11-27 07:47:15.09791+00	\N	710	165	driver	income	10000.00	pending	t
510	2024-11-27 08:54:47.551514+00	2024-11-27 08:54:47.551514+00	\N	711	164	driver	income	10000.00	pending	t
511	2024-11-27 08:54:47.680794+00	2024-11-27 08:54:47.680794+00	\N	711	165	driver	income	10000.00	pending	t
512	2024-11-28 01:37:56.412505+00	2024-11-28 01:37:56.412505+00	\N	713	57	driver	income	500000.00	pending	t
513	2024-11-28 02:43:32.975998+00	2024-11-28 02:43:32.975998+00	\N	714	164	driver	income	10000.00	pending	t
514	2024-11-28 02:43:33.101398+00	2024-11-28 02:43:33.101398+00	\N	714	165	driver	income	10000.00	pending	t
515	2024-11-28 04:01:14.767622+00	2024-11-28 04:01:14.767622+00	\N	715	164	driver	income	10000.00	pending	t
516	2024-11-28 04:01:14.893335+00	2024-11-28 04:01:14.893335+00	\N	715	165	driver	income	10000.00	pending	t
517	2024-11-28 05:58:46.003119+00	2024-11-28 05:58:46.003119+00	\N	716	57	driver	income	500000.00	pending	t
518	2024-11-28 06:11:58.718789+00	2024-11-28 06:11:58.718789+00	\N	717	172	driver	income	10000.00	pending	t
519	2024-11-28 06:22:36.56513+00	2024-11-28 06:24:55.995951+00	\N	718	57	driver	income	500000.00	success	f
520	2024-11-28 06:43:10.043344+00	2024-11-28 06:43:10.043344+00	\N	719	172	driver	income	10000.00	pending	t
521	2024-11-28 06:43:10.170532+00	2024-11-28 06:43:10.170532+00	\N	719	173	driver	income	10000.00	pending	t
522	2024-11-28 07:15:26.477241+00	2024-11-28 07:15:26.477241+00	\N	720	139	driver	income	10000.00	pending	t
523	2024-11-28 07:15:26.605712+00	2024-11-28 07:15:26.605712+00	\N	720	140	driver	income	10000.00	pending	t
524	2024-11-28 07:53:03.086214+00	2024-11-28 08:01:42.965647+00	\N	721	139	driver	income	10000.00	success	f
525	2024-11-28 08:26:15.561946+00	2024-11-28 08:26:15.561946+00	\N	722	139	driver	income	548825.94	pending	t
526	2024-11-28 08:26:15.687373+00	2024-11-28 08:26:15.687373+00	\N	722	140	driver	income	548825.94	pending	t
527	2024-11-28 08:38:48.310694+00	2024-11-28 08:43:02.892275+00	\N	723	139	driver	income	10000.00	success	f
528	2024-11-28 08:48:50.430237+00	2024-11-28 08:48:50.430237+00	\N	724	139	driver	income	10000.00	pending	t
529	2024-11-28 08:58:07.006237+00	2024-11-28 08:58:07.006237+00	\N	725	139	driver	income	10000.00	pending	t
530	2024-11-28 09:03:42.091074+00	2024-11-28 09:03:42.091074+00	\N	726	139	driver	income	10000.00	pending	t
531	2024-11-29 02:07:45.878955+00	2024-11-29 02:07:45.878955+00	\N	727	139	driver	income	10000.00	pending	t
532	2024-11-29 02:07:46.003755+00	2024-11-29 02:07:46.003755+00	\N	727	140	driver	income	10000.00	pending	t
533	2024-11-29 03:29:58.178179+00	2024-11-29 03:29:58.178179+00	\N	728	56	driver	income	20000.00	pending	f
534	2024-11-29 04:17:18.947816+00	2024-11-29 04:19:32.046796+00	\N	729	139	driver	income	708398.17	success	f
535	2024-11-29 06:50:47.682539+00	2024-11-29 06:50:47.682539+00	\N	731	139	driver	income	10000.00	pending	t
536	2024-11-29 06:50:47.807618+00	2024-11-29 06:50:47.807618+00	\N	731	140	driver	income	10000.00	pending	t
537	2024-11-29 07:09:11.191331+00	2024-11-29 07:09:11.191331+00	\N	732	139	driver	income	10000.00	pending	t
538	2024-11-29 07:09:11.315573+00	2024-11-29 07:09:11.315573+00	\N	732	140	driver	income	10000.00	pending	t
539	2024-11-29 07:45:45.672307+00	2024-11-29 07:54:35.227928+00	\N	734	139	driver	income	697964.11	success	f
540	2024-11-29 07:57:38.848816+00	2024-11-29 08:00:40.492636+00	\N	735	139	driver	income	10000.00	success	f
541	2024-11-29 08:09:20.658032+00	2024-11-29 08:34:25.01817+00	\N	736	139	driver	income	10000.00	success	f
542	2024-11-30 07:23:34.020636+00	2024-11-30 07:26:39.269581+00	\N	737	139	driver	income	10000.00	success	f
543	2024-11-30 21:49:56.40427+00	2024-11-30 21:49:56.40427+00	\N	738	57	driver	income	500000.00	pending	t
544	2024-11-30 22:13:30.187045+00	2024-12-01 00:54:20.969113+00	\N	740	180	driver	income	500000.00	success	f
545	2024-12-01 01:39:41.701065+00	2024-12-01 01:39:41.701065+00	\N	741	180	driver	income	500000.00	pending	f
547	2024-12-01 02:09:06.693715+00	2024-12-01 02:09:06.693715+00	\N	743	139	driver	income	500000.00	pending	t
548	2024-12-01 02:09:06.819997+00	2024-12-01 02:09:06.819997+00	\N	743	140	driver	income	500000.00	pending	t
546	2024-12-01 01:43:22.883998+00	2024-12-01 03:21:10.732646+00	\N	742	180	driver	income	500000.00	success	f
549	2024-12-01 03:33:28.022945+00	2024-12-01 03:33:28.022945+00	\N	744	180	driver	income	500000.00	pending	t
550	2024-12-01 04:38:04.045413+00	2024-12-01 04:38:04.045413+00	\N	746	163	driver	income	250000.00	pending	t
551	2024-12-01 04:54:56.926315+00	2024-12-01 04:54:56.926315+00	\N	748	180	driver	income	500000.00	pending	t
552	2024-12-01 05:25:48.765018+00	2024-12-01 05:25:48.765018+00	\N	749	180	driver	income	250000.00	pending	t
553	2024-12-01 05:38:30.24341+00	2024-12-01 05:38:30.24341+00	\N	750	180	driver	income	500000.00	pending	t
554	2024-12-01 05:54:46.885915+00	2024-12-01 05:54:46.885915+00	\N	751	180	driver	income	500000.00	pending	t
555	2024-12-01 12:15:26.207509+00	2024-12-01 12:15:26.207509+00	\N	747	175	driver	income	500000.00	pending	f
556	2024-12-01 12:24:30.291539+00	2024-12-01 12:24:30.291539+00	\N	745	180	driver	income	500000.00	pending	f
557	2024-12-02 00:51:13.446232+00	2024-12-02 00:54:41.178146+00	\N	752	180	driver	income	500000.00	success	f
558	2024-12-02 01:06:30.986665+00	2024-12-02 01:06:30.986665+00	\N	755	180	driver	income	500000.00	pending	t
559	2024-12-02 02:29:08.987278+00	2024-12-02 02:29:08.987278+00	\N	756	180	driver	income	500000.00	pending	t
560	2024-12-02 03:04:25.014716+00	2024-12-02 03:04:25.014716+00	\N	758	180	driver	income	500000.00	pending	t
561	2024-12-02 03:04:53.488174+00	2024-12-02 03:13:32.239682+00	\N	757	163	driver	income	500000.00	success	f
562	2024-12-02 03:37:43.691054+00	2024-12-02 03:37:43.691054+00	\N	759	180	driver	income	500000.00	pending	t
563	2024-12-02 03:40:57.425141+00	2024-12-02 03:40:57.425141+00	\N	760	163	driver	income	500000.00	pending	f
564	2024-12-02 03:47:39.985011+00	2024-12-02 03:47:39.985011+00	\N	761	163	driver	income	500000.00	pending	f
565	2024-12-02 04:13:31.236038+00	2024-12-02 04:13:31.236038+00	\N	762	163	driver	income	500000.00	pending	f
566	2024-12-02 04:19:46.818452+00	2024-12-02 04:19:46.818452+00	\N	763	163	driver	income	500000.00	pending	f
567	2024-12-02 04:23:04.747347+00	2024-12-02 04:23:04.747347+00	\N	764	163	driver	income	500000.00	pending	f
\.


--
-- Data for Name: truck_car; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.truck_car (id, created_at, updated_at, deleted_at, owner_car_id, type_car, label_car, license_car, weight_car, address_to, address_from, provinces_to, districts_to, wards_to, provinces_code_to, districts_code_to, wards_code_to, provinces_from, districts_from, wards_from, provinces_code_from, districts_code_from, wards_code_from, available, truck_status, vehicle_type_id) FROM stdin;
5	2024-04-11 09:58:51.502356+00	2024-09-12 06:56:51.687616+00	\N	5	xe bồn	huyndai	50H-17020	123.00	18, đường 54	74 an Bình	Đồng Tháp	Định Yên	An Bình To	79	762	32259	HCM	Q2	An Bình From	79	762	32259	t	available	\N
8	2024-04-11 09:58:51.502356+00	2024-09-12 06:56:51.773813+00	\N	5	xe bồn	huyndai	59H-21314	123.00	18, đường 54	74 an Bình	Đồng Tháp	Định Yên	An Bình To	79	762	32259	HCM	Q2	An Bình From	79	762	32259	t	available	\N
2	2024-04-12 10:12:13.501421+00	2024-09-12 06:56:51.949697+00	\N	5	xe bồn	huyndai	59H-21312	123.00	18, đường 54	74 an Bình	Đồng Tháp	Định Yên	An Bình To	3344	59	34	HCM	Q2	An Bình From	123	12	43	f	available	\N
7	2024-04-11 09:58:51.502356+00	2024-09-12 06:56:51.860465+00	\N	5	xe bồn	huyndai	50H-18499	123.00	18, đường 54	74 an Bình	Đồng Tháp	Định Yên	An Bình To	79	762	32259	HCM	Q2	An Bình From	79	762	32259	f	available	\N
3	2024-04-11 09:58:51.502356+00	2024-04-21 13:41:46.891858+00	\N	5	xe bồn	huyndai	59H-21313	123.00	18, đường 54	74 an Bình	Đồng Tháp	Định Yên	An Bình To	79	762	32259	HCM	Q2	An Bình From	79	762	32259	t	available	\N
1	2024-04-12 10:12:13.496877+00	2024-04-20 02:51:24.738988+00	\N	5	xe bồn	huyndai	59H-21311	123.00	18, đường 54	74 an Bình	Đồng Tháp	Định Yên	An Bình	3344	23	59	HCM	Q2	Thạnh Mỹ lợi	123	12	34	t	available	\N
4	2024-04-11 09:58:51.502356+00	2024-08-29 06:11:28.809823+00	\N	5	xe bồn	huyndai	50H-17057	123.00	18, đường 54	74 an Bình	Đồng Tháp	Định Yên	An Bình To	79	762	32259	HCM	Q2	An Bình From	79	762	32259	t	available	\N
9	2024-07-19 10:11:44.590186+00	2024-09-09 06:10:54.721038+00	\N	5	xe bồn	huyndai	59-213141	123.00	18, đường 54	74 an Bình	Đồng Tháp	Định Yên	An Bình To	79	762	32259	HCM	Q2	An Bình From	79	762	32259	t	available	\N
6	2024-04-11 09:58:51.502356+00	2024-08-29 06:11:28.564686+00	\N	5	xe bồn	huyndai	50H-09557	123.00	18, đường 54	74 an Bình	Đồng Tháp	Định Yên	An Bình To	3344	59	34	HCM	Q2	An Bình From	79	762	32259	f	available	\N
\.


--
-- Data for Name: truck_components; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.truck_components (id, created_at, updated_at, deleted_at, purchase_date, component_name, component_type, component_cost, component_quantity, warehouse_address, component_status, note, manager_id, vat) FROM stdin;
2	2024-05-30 02:51:16.891085+00	2024-05-30 02:51:16.891085+00	\N	1712308366682	ten linh kien	loai linh kien	100.00	10	dia chi kho	trạng thái linh 		1	\N
4	2024-05-29 10:16:35.674749+00	2024-05-30 06:18:08.161105+00	\N	1712308366682	ten linh kien 2	loai linh kien update	200.00	10	dia chi kho update 	trạng thái update	ghi chu update	3	\N
3	2024-05-29 10:16:35.674749+00	2024-05-30 06:18:08.161105+00	\N	1715495960000	ten linh kien 2	loai linh kien update	500.00	10	dia chi kho update 	trạng thái update	ghi chu update	2	\N
1	2024-05-29 10:16:35.674749+00	2024-05-30 06:18:08.161105+00	\N	1715236760000	ten linh kien update	loai linh kien update	300.00	10	dia chi kho update 	trạng thái update	ghi chu update	1	\N
\.


--
-- Data for Name: user; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public."user" (id, created_at, updated_at, deleted_at, user_name, password_hash, email, full_name, phone_number, day_of_birth, citizen_identity_card, date_of_citizen_card, place_of_citizen_card, address, company_id) FROM stdin;
4	2024-06-07 07:10:05.083048+00	2024-06-07 07:10:05.083048+00	\N	huynhtran	$2a$10$3LDwszED1zP6A4ztNJsTSeewPNcJgNPxpES.ZTBuwEhBnl2fkmfGi	phophongkinhdoanh@gmail.com	Huynh Tran	123456704	11/11/2011	123456704	11/11/2011	Sai Gon	Sai Gon	1
11	2024-06-07 08:32:22.141218+00	2024-06-07 08:32:22.141218+00	\N	motnguyen	$2a$10$3LDwszED1zP6A4ztNJsTSeewPNcJgNPxpES.ZTBuwEhBnl2fkmfGi	linh1@mail.com	Nguyễn Văn Một	0898776352	11/11/2011	241966892	11/11/2011	Sai Gon	Sai Gon	1
5	2024-06-07 07:11:01.178537+00	2024-06-07 07:11:01.178537+00	\N	ngocdiem	$2a$10$3LDwszED1zP6A4ztNJsTSeewPNcJgNPxpES.ZTBuwEhBnl2fkmfGi	nhanvienkinhdoanh1@gmail.com	Ngoc Diem	123456705	11/11/2011	123456705	11/11/2011	Sai Gon	Sai Gon	1
7	2024-06-07 07:11:01.178537+00	2024-06-07 07:11:01.178537+00	\N	thien	$2a$10$3LDwszED1zP6A4ztNJsTSeewPNcJgNPxpES.ZTBuwEhBnl2fkmfGi	truongphongketoan@gmail.com	Thien	123456707	11/11/2011	123456707	11/11/2011	Sai Gon	Sai Gon	1
3	2024-06-07 04:26:53.323825+00	2024-06-07 04:26:53.323825+00	\N	khanh	$2a$10$3LDwszED1zP6A4ztNJsTSeewPNcJgNPxpES.ZTBuwEhBnl2fkmfGi	truongphongkinhdoanh@gmail.com	Khanh	123456703	11/11/2011	123456703	11/11/2011	Sai Gon	Sai Gon	1
6	2024-06-07 07:11:01.178537+00	2024-06-07 07:11:01.178537+00	\N	caochau	$2a$10$3LDwszED1zP6A4ztNJsTSeewPNcJgNPxpES.ZTBuwEhBnl2fkmfGi	nhanvienkinhdoanh2@gmail.com	Cao Chau	123456706	11/11/2011	123456706	11/11/2011	Sai Gon	Sai Gon	1
1	2024-06-07 04:26:53.323825+00	2024-06-07 04:26:53.323825+00	\N	hoanguyen	$2a$10$3LDwszED1zP6A4ztNJsTSeewPNcJgNPxpES.ZTBuwEhBnl2fkmfGi	giamdoc@gmail.com	Nguyen Thanh Hoa	123456701	11/11/2011	123456701	11/11/2011	Sai Gon	Sai Gon	1
9	2024-06-07 07:11:01.178537+00	2024-06-07 07:11:01.178537+00	\N	lehuong	$2a$10$3LDwszED1zP6A4ztNJsTSeewPNcJgNPxpES.ZTBuwEhBnl2fkmfGi	nhanvienketoan2@gmail.com	Le Huong	123456709	11/11/2011	123456709	11/11/2011	Sai Gon	Sai Gon	1
10	2024-06-07 07:11:01.178537+00	2024-06-07 07:11:01.178537+00	\N	hoangminhquang	$2a$10$3LDwszED1zP6A4ztNJsTSeewPNcJgNPxpES.ZTBuwEhBnl2fkmfGi	kinhdoanhquocte@gmail.com	Hoang Minh Quang	123456710	11/11/2011	123456710	11/11/2011	Sai Gon	Sai Gon	1
8	2024-06-07 07:11:01.178537+00	2024-06-07 07:11:01.178537+00	\N	touyen	$2a$10$3LDwszED1zP6A4ztNJsTSeewPNcJgNPxpES.ZTBuwEhBnl2fkmfGi	nhanvienketoan1@gmail.com	To Uyen	123456708	11/11/2011	123456708	11/11/2011	Sai Gon	Sai Gon	1
119	2024-06-14 06:37:26.334364+00	2024-06-14 06:37:26.334364+00	\N	Michele82	$2a$14$1zLLLBPn1qWcmGuRpTX7eeLX8LXUbKB5uu8RL14vw5wsrIoDrQaDW	Monty.Stark@gmail.com	Mandy Jenkins	664-572-6407	11/11/2011	1234567071	11/11/2011	Sai Gon	Sai Gon	1
128	2024-06-20 09:54:41.276955+00	2024-06-20 09:54:41.276955+00	\N	Merritt91	$2a$14$r/.4Vc6B0n.yb.HArdCaj.HzE3gWtNAABk9oyqubR00KsLR7q5B3m	Narciso81@hotmail.com	Irvin Bednar	538-909-9317	11/11/2011	1234561111	11/11/2011	sai gon	sai gon	1
120	2024-06-14 06:56:06.249729+00	2024-06-14 06:56:06.249729+00	\N	Alexandre.Monahan33	$2a$14$ohDX9Yfu.6w.6JDluXPCk.6.osgsveINA5Tvrw0y6RYGFQRkJQqIm	Yazmin_Boyle77@gmail.com	Alicia Ritchie	760-495-2675	11/11/2011	1234567081	11/11/2011	Sai Gon	Sai Gon	1
12	2024-06-13 04:33:06.020738+00	2024-06-13 04:33:06.020738+00	\N	super_admin	$2a$10$3LDwszED1zP6A4ztNJsTSeewPNcJgNPxpES.ZTBuwEhBnl2fkmfGi	giamdoc1@gmail.com	Nguyen Thanh Hoa 1	123456101	11/11/2011	1234567017	11/11/2011	Sai Gon	Sai Gon	1
135	2024-06-21 10:26:05.809209+00	2024-06-21 10:26:05.809209+00	\N	Mabelle.Pagac	$2a$10$3LDwszED1zP6A4ztNJsTSeewPNcJgNPxpES.ZTBuwEhBnl2fkmfGi	Kurt.Schneider@gmail.com	Eva Kutch	734-883-1520	21/21/2121	21/21/2121	21/21/2121	saigon	saigon	0
123	2024-06-20 09:22:11.711115+00	2024-06-20 09:22:11.711115+00	\N	Hassie.Streich	$2a$14$rtZkBGrGDdKKueTh6lS/1uFhin/tlBq9Akjq5crqGCaZucU3Wh.Ai	Kiara19@hotmail.com	Felicia Mitchell	599-244-9076	11/11/2011	1234567111	11/11/2011	sai gon	sai gon	1
129	2024-06-20 09:56:49.418335+00	2024-06-20 09:56:49.418335+00	\N	Ellis85	$2a$14$QwcGwGnBxdrN8t99TzvOPOktdQreUTyGcEqtUcqFJILK5S4osquQC	Jammie.Brown24@hotmail.com	Marco Donnelly	658-546-9243	11/11/2011	1234561211	11/11/2011	sai gon	sai gon	1
130	2024-06-20 09:56:55.254755+00	2024-06-20 09:56:55.254755+00	\N	Karolann_Fadel38	$2a$14$0ssrMuNfkMxJ.B4QUwZmiedKKFzs21.mln/yvCnUDiLL/0jvmAqoK	Audreanne_Grady@hotmail.com	Dr. Omar Thompson	473-555-4533	11/11/2011	1234561231	11/11/2011	sai gon	sai gon	1
131	2024-06-20 09:57:04.003101+00	2024-06-20 09:57:04.003101+00	\N	Winfield_Hickle	$2a$14$vxrmE.Lp9s8/QlzsqI/HGufEWvgtbOK7ZugdUfNbR/LBcuq8reJc6	Waino_OConner64@yahoo.com	Miss Dana Bode	572-508-4080	11/11/2011	1234561234	11/11/2011	sai gon	sai gon	1
132	2024-06-21 03:48:40.317697+00	2024-06-21 03:48:40.317697+00	\N	Jaylan_Smitham17	$2a$14$hNjAHDXLHvXlG7fZhjB68e.PFpwL8dsM7wz9uWz3Fc/uwmGFuLTlS	Brandt62@hotmail.com	Susan Kozey	393-564-4024	11/11/2011	1234561233	11/11/2011	sai gon	sai gon	1
121	2024-06-14 06:58:10.00809+00	2024-06-21 06:58:27.131019+00	\N	Kyla.Walsh	$2a$14$1/bPT.OZQuP.2XYc2CO85e2XbBtihTTUMm/FEf5eJMOz4.Ejtg0QW	Keara.Hirthe95@gmail.com	Felipe Gutmann	892-398-9955	11/11/2011	1234567091	11/11/2011	Sai Gon	Sai Gon	1
2	2024-06-07 04:26:53.323825+00	2024-06-24 03:42:39.975336+00	\N	tungpham	$2a$14$pMFgW1giAUd4alc2RvhJx.mE5ChrJBHDZ2pERljbqzk5Mg9QzZ.aK	phogiamdoc@gmail.com	Tung Pham	123456702	11/11/2011	123456702	11/11/2011	Sai Gon	Sai Gon	1
140	2024-07-01 07:10:03.509506+00	2024-07-01 07:10:03.509506+00	\N	Bonita.Hettinger32	$2a$14$v9uHLN.FnZRsp9GkJGHofe66UsQEJMyMmluUf0995Wk1ELbBFReGW	Reta.Schuppe@yahoo.com	Shelia Friesen	324-629-3176	21/21/2121	629	21/21/2121	saigon	saigon	0
141	2024-07-01 07:25:24.80488+00	2024-07-01 07:25:24.80488+00	\N	Ronny.Ziemann14	$2a$14$WjQQPengJoJtLh1sJ46TRuem1WpaTsWKmby7WNpjt7ffaW1i3sSHq	Margarete_Wisoky38@gmail.com	Dewey Larson	543-821-0443	21/21/2121	565	21/21/2121	saigon	saigon	0
142	2024-07-01 07:26:42.495613+00	2024-07-01 07:26:42.495613+00	\N	Carlie26	$2a$14$vlAgjay8VwLaWUfre9jyq.FQebDZdcJJVxIIXLKuxxr4HNC2KJXI6	Saige_Kihn12@gmail.com	Edward Rutherford	761-669-0657	21/21/2121	952	21/21/2121	saigon	saigon	0
137	2024-06-24 10:16:29.076296+00	2024-06-25 23:04:24.019733+00	\N	Evie75	$2a$10$3LDwszED1zP6A4ztNJsTSeewPNcJgNPxpES.ZTBuwEhBnl2fkmfGi	Lorenz.Koepp@yahoo.com	Enrique Schaden	785-730-7347	21/21/2121	123456789	21/21/2121	saigon	saigon	1
143	2024-07-01 07:31:35.266815+00	2024-07-01 07:31:35.266815+00	\N	Alfred.Torp	$2a$14$JbGz.8JdVSlC31TweTrypu70gSvJ7iB98GduRypXXHoOEpDHr/eP.	Tierra_Lowe1@hotmail.com	Andy Mante	857-805-8076	21/21/2121	234	21/21/2121	saigon	saigon	0
\.


--
-- Data for Name: user_department; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.user_department (id, created_at, updated_at, deleted_at, user_id, department_id, company_id) FROM stdin;
1	2024-06-07 07:40:33.825651+00	2024-06-07 07:40:33.825651+00	\N	1	1	1
2	2024-06-07 07:40:38.936411+00	2024-06-07 07:40:38.936411+00	\N	2	1	1
3	2024-06-07 07:40:49.889392+00	2024-06-07 07:40:49.889392+00	\N	3	2	1
4	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00	\N	4	2	1
5	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00	\N	5	2	1
6	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00	\N	6	2	1
7	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00	\N	7	3	1
8	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00	\N	8	3	1
9	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00	\N	9	3	1
10	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00	\N	10	5	1
11	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00	\N	11	5	1
12	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00	\N	12	5	1
13	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00	\N	119	5	1
14	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00	\N	120	5	1
15	2024-06-17 10:23:57.434308+00	2024-06-17 10:23:57.434308+00	\N	121	5	1
16	2024-06-20 09:57:04.023718+00	2024-06-20 09:57:04.023718+00	\N	131	2	1
17	2024-06-21 03:48:40.33464+00	2024-06-21 03:48:40.33464+00	\N	132	2	1
18	2024-06-21 06:39:31.593462+00	2024-06-21 06:39:31.593462+00	\N	12	1	1
19	2024-06-25 23:04:46.654166+00	2024-06-25 23:04:46.654166+00	\N	137	5	1
\.


--
-- Data for Name: user_role; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.user_role (id, created_at, updated_at, deleted_at, user_id, role_id, company_id) FROM stdin;
1	2024-06-07 08:47:44.074314+00	2024-06-07 08:47:44.074314+00	\N	1	1	1
2	2024-06-07 08:51:48.742286+00	2024-06-07 08:51:48.742286+00	\N	2	2	1
5	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00	\N	5	8	1
6	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00	\N	6	8	1
7	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00	\N	7	3	1
9	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00	\N	9	7	1
10	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00	\N	10	9	1
11	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00	\N	11	13	1
12	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00	\N	12	9999	1
13	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00	\N	119	13	1
14	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00	\N	120	13	1
15	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00	\N	121	13	1
4	2024-06-11 01:59:53.302258+00	2024-06-11 01:59:53.302258+00	\N	4	6	1
3	2024-06-12 08:51:46.564174+00	2024-06-12 08:51:46.564174+00	\N	3	3	1
8	2024-06-17 10:00:08.51137+00	2024-06-17 10:00:08.51137+00	\N	8	7	1
16	2024-06-20 09:22:11.72266+00	2024-06-20 09:22:11.72266+00	\N	123	1	1
17	2024-06-20 09:54:41.286952+00	2024-06-20 09:54:41.286952+00	\N	128	1	1
18	2024-06-20 09:56:49.43323+00	2024-06-20 09:56:49.43323+00	\N	129	1	1
19	2024-06-20 09:56:55.267961+00	2024-06-20 09:56:55.267961+00	\N	130	1	1
20	2024-06-20 09:57:04.01418+00	2024-06-20 09:57:04.01418+00	\N	131	1	1
21	2024-06-21 03:48:40.329964+00	2024-06-21 03:48:40.329964+00	\N	132	1	1
24	2024-06-25 23:04:43.967721+00	2024-06-25 23:04:43.967721+00	\N	137	13	1
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.users (id, user_name, email, first_name, last_name, status, hash_password, role, created_at, updated_at, deleted_at) FROM stdin;
\.


--
-- Data for Name: variables; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.variables (id, created_at, updated_at, deleted_at, owner_id, name, code) FROM stdin;
1	2024-11-12 10:22:23.319903+00	2024-11-12 10:22:23.319903+00	\N	4	tiền cầu đường	FOR1
2	2024-11-12 10:22:49.345163+00	2024-11-12 10:22:49.345163+00	\N	4	tiền lương tài xế	FOR2
3	2024-11-12 10:24:53.642372+00	2024-11-12 10:24:53.642372+00	\N	4	tiền dầu	FOR3
4	2024-11-12 10:24:53.642372+00	2024-11-12 10:24:53.642372+00	\N	4	tiền lốp	FOR4
5	2024-11-12 10:24:53.642372+00	2024-11-12 10:24:53.642372+00	\N	4	khấu hao xe	FOR5
6	2024-11-12 10:24:53.642372+00	2024-11-12 10:24:53.642372+00	\N	4	luật	FOR6
7	2024-11-12 10:24:53.642372+00	2024-11-12 10:24:53.642372+00	\N	4	tiền hỗ trợ	FOR7
8	2024-11-12 10:24:53.642372+00	2024-11-12 10:24:53.642372+00	\N	4	lợi nhuận	FOR8
\.


--
-- Data for Name: vehicle_types; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.vehicle_types (id, created_at, updated_at, deleted_at, type_name, description) FROM stdin;
1	2024-10-17 08:39:55.695907+00	2024-10-17 08:39:55.695907+00	\N	xe bồn	
2	2024-10-21 08:45:34.725153+00	2024-10-21 08:45:34.725153+00	\N	xe đầu kéo	
3	2024-10-21 08:45:44.959609+00	2024-10-21 08:45:44.959609+00	\N	xe tải	
4	2024-10-29 07:22:05.633637+00	2024-10-29 07:22:05.633637+00	\N	xe tải 40	xe 40 tấn
6	2024-11-03 11:16:13.389382+00	2024-11-03 11:16:13.389382+00	\N	dad	d
7	2024-11-03 11:34:42.863093+00	2024-11-03 11:34:42.863093+00	\N	d	d
8	2024-11-03 11:53:33.937587+00	2024-11-03 11:53:33.937587+00	\N	xe tai 50t	50 tan
5	2024-11-03 11:10:26.850439+00	2024-11-03 11:10:26.850439+00	\N	xe ben	xe ben 40 tan
9	2024-11-14 07:40:14.615802+00	2024-11-14 07:40:14.615802+00	\N	xe ô tô	
10	2024-11-14 08:12:23.607825+00	2024-11-14 08:12:23.607825+00	\N	vm	VM
11	2024-11-15 07:43:19.37481+00	2024-11-15 07:43:19.37481+00	\N	xe bồn 2	
12	2024-11-15 07:56:55.324783+00	2024-11-15 07:56:55.324783+00	\N	xe bồn 3	
13	2024-11-15 08:44:51.029635+00	2024-11-15 08:44:51.029635+00	\N	xe bồn 4	
14	2024-11-18 05:48:16.471408+00	2024-11-18 05:48:16.471408+00	\N	sd	
15	2024-11-18 05:49:15.412152+00	2024-11-18 05:49:15.412152+00	\N	a	
16	2024-11-18 07:52:03.89266+00	2024-11-18 07:52:03.89266+00	\N	xe hoi 2.0	xe cho nguoi
49	2024-11-19 03:42:30.699553+00	2024-11-19 03:42:30.699553+00	\N	xe container	50 tấn
82	2024-11-19 07:08:53.167885+00	2024-11-19 07:08:53.167885+00	\N	xe container 2	
115	2024-11-20 06:05:51.756099+00	2024-11-20 06:05:51.756099+00	\N	xe hàng	xe chở phế liệu
116	2024-11-20 07:00:48.983048+00	2024-11-20 07:00:48.983048+00	\N	xe phế liệu	
117	2024-11-20 07:17:46.919941+00	2024-11-20 07:17:46.919941+00	\N	xe phế liệu 2	
118	2024-11-20 08:20:26.565007+00	2024-11-20 08:20:26.565007+00	\N	xe phế liệu 3	
119	2024-11-20 08:20:39.678641+00	2024-11-20 08:20:39.678641+00	\N	phế liệu	
120	2024-11-20 08:32:38.0136+00	2024-11-20 08:32:38.0136+00	\N	xe rác	
121	2024-11-20 09:54:31.749415+00	2024-11-20 09:54:31.749415+00	\N	xe xi măng	
122	2024-11-21 08:29:12.447687+00	2024-11-21 08:29:12.447687+00	\N	tàu ngầm	
155	2024-11-21 09:37:49.811001+00	2024-11-21 09:37:49.811001+00	\N	xe container 100	
156	2024-11-22 03:08:03.549417+00	2024-11-22 03:08:03.549417+00	\N	tàu hỏa	
157	2024-11-22 03:08:10.360693+00	2024-11-22 03:08:10.360693+00	\N	tàu	
158	2024-11-22 04:11:47.428062+00	2024-11-22 04:11:47.428062+00	\N	xe chở bánh tráng	
159	2024-11-23 03:59:14.750766+00	2024-11-23 03:59:14.750766+00	\N	tàu bè	
160	2024-11-26 07:38:15.388305+00	2024-11-26 07:38:15.388305+00	\N	container 99	
161	2024-11-30 22:05:20.009452+00	2024-11-30 22:05:20.009452+00	\N	dev	xu ly loi
162	2024-12-02 03:32:51.514773+00	2024-12-02 03:32:51.514773+00	\N	container 101	
\.


--
-- Data for Name: vehicles; Type: TABLE DATA; Schema: public; Owner: root
--

COPY public.vehicles (id, created_at, updated_at, deleted_at, owner_id, description, load, vehicle_type_id, vehicle_status, vehicle_plate, additional_plate) FROM stdin;
11	2024-11-03 20:23:49.146743+00	2024-11-03 20:23:49.146743+00	\N	4		1000.00	1	available	50H-17023	50H-27023
20	2024-11-07 09:13:09.004759+00	2024-11-19 08:52:12.606886+00	\N	4		1000.00	1	unavailable	50H-17033	50H-27033
19	2024-11-07 09:13:08.342+00	2024-11-19 08:55:40.040726+00	\N	4		1000.00	1	unavailable	50H-17031	50H-27031
32	2024-11-15 04:19:56.403617+00	2024-11-15 04:19:56.403617+00	\N	4		50.00	1	available	339-488-0025	664-292-7458
30	2024-11-11 15:23:42.67872+00	2024-11-11 15:23:42.67872+00	\N	4		50.00	1	available	0123456789	0123456789
28	2024-11-08 06:46:21.133328+00	2024-11-08 06:46:21.133328+00	\N	4	ko	100.00	1	available	50H-10000	59H-3000
251	2024-11-20 07:19:04.870074+00	2024-11-20 07:21:01.85313+00	\N	4	fgh	100.00	117	available	50h7889	\N
38	2024-11-15 07:13:26.384876+00	2024-11-15 07:13:26.384876+00	\N	4	ko	100.00	1	available	50H-12349	\N
22	2024-11-07 09:13:10.35035+00	2024-11-19 09:01:01.396623+00	\N	4		1000.00	1	unavailable	50H-17035	50H-27035
12	2024-11-03 20:25:06.776634+00	2024-11-03 20:25:06.776634+00	\N	4		1000.00	2	available	50H-17021	50H-27021
24	2024-11-07 09:13:11.630625+00	2024-11-19 09:10:02.081956+00	\N	4		1000.00	1	unavailable	50H-17034	50H-27034
10	2024-11-03 20:22:04.764772+00	2024-11-03 20:22:04.764772+00	\N	4		1000.00	1	available	50H-17024	50H-27024
34	2024-11-15 07:04:21.077385+00	2024-11-15 07:04:21.077385+00	\N	4	qq	10.00	1	available	50H-12345	\N
252	2024-11-20 07:33:03.153693+00	2024-11-20 07:33:57.645455+00	\N	4	bn	50.00	117	available	59h12347	\N
253	2024-11-20 07:40:42.12181+00	2024-11-20 07:41:31.000848+00	\N	4	k	10.00	115	available	59H-56432	\N
248	2024-11-20 05:19:14.516242+00	2024-11-20 05:19:14.516242+00	\N	4	ko	10.00	2	available	50H-123456	\N
1	2024-10-17 08:41:35.943242+00	2024-10-17 08:41:35.943242+00	\N	4		1000.00	3	available	59H-21312	59H-31312
114	2024-11-18 07:56:07.840378+00	2024-11-18 07:56:07.840378+00	\N	4	ko	100.00	3	available	50H-10909	\N
39	2024-11-15 07:14:18.39744+00	2024-11-15 07:14:18.39744+00	\N	4		150.00	1	available	50H-87643	\N
9	2024-10-21 09:11:43.394657+00	2024-11-18 07:33:26.65662+00	\N	4		1000.00	1	unavailable	49A-78541	49A-48699
21	2024-11-07 09:13:09.729865+00	2024-11-20 04:01:46.628961+00	\N	4		1000.00	1	unavailable	50H-17026	50H-27026
23	2024-11-07 09:13:10.963159+00	2024-11-20 06:33:49.533875+00	\N	4		1000.00	1	unavailable	50H-17028	50H-27028
33	2024-11-15 04:23:51.00668+00	2024-11-20 06:37:02.93243+00	\N	4		150.00	1	unavailable	371-765-3751	511-890-0412
15	2024-11-07 09:13:00.002847+00	2024-11-20 06:40:15.113647+00	\N	4		1000.00	1	unavailable	50H-17036	50H-27036
250	2024-11-20 07:02:17.485402+00	2024-11-20 07:02:17.485402+00	\N	4	abc	50.00	116	driverless	50H67854	\N
29	2024-11-11 15:21:59.993251+00	2024-11-11 15:21:59.993251+00	\N	4		50.00	1	available	309-352-0535	920-311-6949
37	2024-11-15 07:12:25.28425+00	2024-11-15 07:12:25.28425+00	\N	4		150.00	1	available	50H-87633	987-739-2349
42	2024-11-15 08:04:49.161177+00	2024-11-15 08:04:49.161177+00	\N	4		150.00	12	available	50H-97673	\N
46	2024-11-15 08:45:20.020761+00	2024-11-15 08:45:20.020761+00	\N	4		150.00	13	available	50H-89577	\N
41	2024-11-15 07:45:20.064366+00	2024-11-15 07:45:20.064366+00	\N	4		150.00	11	available	50H-97643	\N
27	2024-11-08 04:33:04.133366+00	2024-11-08 04:33:04.133366+00	\N	4		50.00	1	available	837-700-3975	785-516-8541
31	2024-11-14 07:37:17.513406+00	2024-11-14 07:37:17.513406+00	\N	4		100.00	5	available	123456	276-405-7014
147	2024-11-18 07:56:53.429702+00	2024-11-18 07:56:53.429702+00	\N	4	ko	100.00	2	available	50H-909991	\N
35	2024-11-15 07:08:32.691558+00	2024-11-15 07:08:32.691558+00	\N	4		150.00	1	available	462-320-6183	774-254-9117
36	2024-11-15 07:09:04.786767+00	2024-11-15 07:09:04.786767+00	\N	4		150.00	1	available	655-341-1454	785-300-1101
81	2024-11-18 05:25:18.308643+00	2024-11-18 05:25:18.308643+00	\N	4	ab	10000.00	2	available	50H10000	\N
4	2024-10-21 09:11:43.394657+00	2024-11-18 08:06:21.990562+00	\N	4		1000.00	1	unavailable	50H-17020	50H-27020
3	2024-10-21 09:11:21.69365+00	2024-11-18 13:27:30.583279+00	\N	4		1000.00	2	unavailable	50H-09557	50H-19557
5	2024-10-21 09:33:09.144438+00	2024-11-18 13:27:30.59311+00	\N	4		1000.00	1	unavailable	50H-17057	50H-27057
6	2024-10-21 09:11:43.394657+00	2024-11-18 14:45:20.765849+00	\N	4		1000.00	1	unavailable	49A-98213	49A-63247
7	2024-10-21 09:11:43.394657+00	2024-11-18 14:45:20.773154+00	\N	4		1000.00	1	unavailable	49A-56372	49A-88521
180	2024-11-19 04:02:08.810854+00	2024-11-19 04:02:08.810854+00	\N	4	abc	50.00	49	unavailable	50H12345	\N
213	2024-11-19 04:10:42.700985+00	2024-11-19 04:10:42.700985+00	\N	4	note	10.00	1	unavailable	50h45678	\N
246	2024-11-19 06:12:49.478208+00	2024-11-19 06:12:49.478208+00	\N	4	tải trọng xe	50.00	1	unavailable	50H97374	\N
14	2024-11-07 09:12:39.128443+00	2024-11-21 04:53:36.147256+00	\N	4		1000.00	1	unavailable	50H-17025	50H-27025
26	2024-11-07 09:26:43.171135+00	2024-11-07 09:26:43.171135+00	\N	4		1000.00	1	empty	405-813-5623	469-395-4068
16	2024-11-07 09:13:06.182573+00	2024-11-19 08:31:48.588138+00	\N	4		1000.00	1	unavailable	50H-17029	50H-27029
17	2024-11-07 09:13:06.91953+00	2024-11-19 08:37:33.690241+00	\N	4		1000.00	1	unavailable	50H-17030	50H-27030
18	2024-11-07 09:13:07.678231+00	2024-11-20 06:40:15.118683+00	\N	4		1000.00	1	unavailable	50H-17032	50H-27032
254	2024-11-20 08:09:05.681898+00	2024-11-20 08:20:50.396826+00	\N	4		50.00	1	available	66A-66666	66A-66667
255	2024-11-20 08:22:10.738955+00	2024-11-20 08:23:30.600202+00	\N	4	hjk	50.00	118	available	59h78964	\N
257	2024-11-20 08:34:09.654659+00	2024-11-20 08:47:47.68834+00	\N	4	0bn	100.00	120	unavailable	59h23789	\N
247	2024-11-19 09:40:38.037897+00	2024-11-19 09:40:38.037897+00	\N	4	ko	50.00	1	unavailable	55G-87734	\N
260	2024-11-20 09:13:47.7897+00	2024-11-21 06:35:14.503136+00	\N	4	f	11.00	120	unavailable	50H-11112	\N
261	2024-11-20 09:55:52.408044+00	2024-11-21 06:43:16.287293+00	\N	4	vb	100.00	121	unavailable	50h76889	\N
43	2024-11-15 08:22:19.538909+00	2024-11-15 08:22:19.538909+00	\N	4		150.00	12	available	50H-87673	\N
47	2024-11-15 08:46:35.64719+00	2024-11-15 08:46:35.64719+00	\N	4		150.00	13	available	50H-89578	\N
40	2024-11-15 07:14:50.144853+00	2024-11-15 07:14:50.144853+00	\N	4	ko	100.00	2	available	50H-12340	\N
256	2024-11-20 08:30:55.54841+00	2024-11-21 09:38:58.154255+00	\N	4		50.00	1	available	66A-66668	66A-66669
249	2024-11-20 06:07:26.223415+00	2024-11-20 06:07:26.223415+00	\N	4	ko	30.00	115	available	59H-45678	\N
331	2024-11-21 08:31:00.644203+00	2024-11-22 01:25:06.891731+00	\N	4	đfg	100.00	122	available	50h7765	\N
8	2024-10-21 09:11:43.394657+00	2024-11-22 03:52:30.731821+00	\N	4		1000.00	1	available	49A-35520	49A-35722
298	2024-11-21 06:40:38.919303+00	2024-11-22 04:26:44.295741+00	\N	4	ko	55.00	1	available	49A456	49B456
265	2024-11-21 06:36:31.601735+00	2024-11-22 04:26:44.42172+00	\N	4	ko	50.00	1	available	49A123	49B123
263	2024-11-20 10:11:59.157769+00	2024-11-22 05:02:14.596343+00	\N	4	ko	50.00	1	available	50H-87124	\N
364	2024-11-21 08:32:38.806562+00	2024-11-22 06:49:09.967927+00	\N	4	ghu	100.00	122	available	50h778	\N
13	2024-11-05 07:12:52.077628+00	2024-11-19 07:35:08.541935+00	\N	4		1000.00	3	available	50H-17022	50H-27022
258	2024-11-20 08:52:57.915625+00	2024-11-29 03:29:56.808081+00	\N	4	â	100.00	120	unavailable	59h999	\N
264	2024-11-20 10:16:30.581869+00	2024-11-27 04:27:02.931287+00	\N	4	ggh	50.00	2	unavailable	50b56784	\N
259	2024-11-20 09:02:44.201333+00	2024-12-01 04:32:54.589609+00	\N	4	ko	10.00	155	unavailable	50H-12564	\N
45	2024-11-15 08:32:52.933837+00	2024-11-15 08:32:52.933837+00	\N	4		150.00	12	available	50H-87577	\N
44	2024-11-15 08:28:07.481829+00	2024-11-15 08:28:07.481829+00	\N	4		150.00	12	available	50H-87573	\N
25	2024-11-07 09:13:12.728233+00	2024-11-21 08:55:03.357569+00	\N	4		1000.00	1	available	50H-17027	50H-27027
397	2024-11-21 09:28:50.06775+00	2024-11-21 09:30:41.357601+00	\N	4	dd	100.00	120	available	50h7766	\N
398	2024-11-21 09:29:15.674599+00	2024-11-21 09:34:17.938085+00	\N	4	ghh	100.00	120	available	50h7789	\N
418	2024-11-22 08:20:34.450787+00	2024-11-22 08:29:07.321321+00	\N	4	hhhn	50.00	155	unavailable	40h7756	\N
399	2024-11-21 09:39:36.28101+00	2024-11-21 10:08:41.299455+00	\N	4	hhh	100.00	155	unavailable	40h776	\N
400	2024-11-21 09:41:13.910147+00	2024-11-21 10:08:41.508152+00	\N	4	jj	100.00	155	unavailable	40h778	\N
423	2024-11-22 09:53:33.171632+00	2024-12-02 04:23:02.925684+00	\N	4	bxnxb	50.00	155	unavailable	60h3489	\N
407	2024-11-22 07:14:55.601664+00	2024-11-22 07:14:55.601664+00	2024-11-22 04:54:17.601663+00	4	ko	50.00	1	driverless	465-233-2717	\N
410	2024-11-22 07:16:57.62441+00	2024-11-22 07:16:57.62441+00	2024-11-22 04:54:17.601663+00	4	ko	50.00	1	driverless	240-898-3311	\N
411	2024-11-22 07:17:06.117931+00	2024-11-22 07:17:06.117931+00	2024-11-22 04:54:17.601663+00	4	ko	50.00	1	driverless	599-900-6668	tesst12a3
405	2024-11-22 07:01:37.679696+00	2024-11-22 07:01:37.679696+00	2024-11-22 04:54:17.601663+00	4	ko	50.00	1	driverless	810-765-1110	\N
408	2024-11-22 07:15:01.810546+00	2024-11-22 07:15:01.810546+00	2024-11-22 04:54:17.601663+00	4	ko	50.00	1	driverless	834-940-8788	tesst123
404	2024-11-22 04:54:17.601663+00	2024-11-22 04:54:17.601663+00	2024-11-22 04:54:17.601663+00	4	ko	50.00	1	driverless	631-520-6665	\N
406	2024-11-22 07:14:50.36085+00	2024-11-22 07:14:50.36085+00	2024-11-22 04:54:17.601663+00	4	ko	50.00	1	driverless	820-513-6797	\N
409	2024-11-22 07:16:53.570049+00	2024-11-22 07:16:53.570049+00	2024-11-22 04:54:17.601663+00	4	ko	50.00	1	driverless	238-336-9433	\N
419	2024-11-22 09:14:53.52496+00	2024-11-22 09:21:49.537921+00	\N	4	hhhj	50.00	155	unavailable	60h7889	\N
403	2024-11-22 04:53:51.718653+00	2024-11-22 07:46:08.424509+00	\N	4	nnn	50.00	155	unavailable	40h3657	\N
412	2024-11-22 07:17:50.886183+00	2024-11-22 07:46:08.651735+00	\N	4	nznznq	50.00	155	unavailable	40h3658	\N
431	2024-11-25 10:00:51.175548+00	2024-11-25 10:02:08.350282+00	\N	4	bbj	50.00	155	available	60h68907	\N
432	2024-11-26 03:49:49.919876+00	2024-11-28 06:43:07.966906+00	\N	4	jdjsbd	50.00	155	unavailable	60h4576	\N
420	2024-11-22 09:18:59.321176+00	2024-11-22 09:21:49.744076+00	\N	4	bbb	50.00	155	unavailable	60h7764	\N
433	2024-11-26 06:24:33.435978+00	2024-11-28 06:43:08.175997+00	\N	4	bbnj	50.00	155	unavailable	60h6784	\N
402	2024-11-22 04:49:29.544753+00	2024-11-26 01:57:47.920386+00	\N	4	njsb	50.00	155	available	40h777	\N
421	2024-11-22 09:29:32.066225+00	2024-11-22 09:40:46.952921+00	\N	4	nnn	50.00	155	unavailable	60h7785	\N
415	2024-11-22 08:04:30.650837+00	2024-11-22 08:16:23.652355+00	\N	4	nnn	50.00	155	unavailable	40h8978	\N
416	2024-11-22 08:06:51.627812+00	2024-11-22 08:16:23.85956+00	\N	4	nmm	50.00	155	unavailable	40h6887	\N
422	2024-11-22 09:30:45.674353+00	2024-11-22 09:40:47.159111+00	\N	4	 bnmm	50.00	155	unavailable	60h7774	\N
424	2024-11-22 09:55:24.697294+00	2024-11-26 01:59:26.28449+00	\N	4	nnj	50.00	155	available	60h3564	\N
425	2024-11-23 03:57:20.329411+00	2024-11-23 03:58:26.015355+00	\N	4	bbj	100.00	155	available	40h3678	\N
417	2024-11-22 08:18:04.131366+00	2024-11-22 08:29:07.113623+00	\N	4	ssd	50.00	155	unavailable	40h6756	\N
426	2024-11-23 04:00:30.762336+00	2024-11-25 01:52:02.224724+00	\N	4	hụ	100.00	159	available	40h7746	\N
427	2024-11-25 03:39:46.915753+00	2024-11-25 03:50:04.796195+00	\N	4	bznznz	50.00	155	available	60h7789	\N
48	2024-11-18 05:10:06.390135+00	2024-11-25 03:58:50.091884+00	\N	4	ko	100.00	1	available	50H-09898	\N
435	2024-11-26 07:39:56.220347+00	2024-12-01 12:15:25.825892+00	\N	4	vhhv	50.00	160	unavailable	60h77890	\N
430	2024-11-25 08:02:55.498014+00	2024-11-26 04:41:59.517472+00	\N	4	bbb	50.00	155	unavailable	50h48979	\N
414	2024-11-22 07:49:06.148099+00	2024-12-01 02:09:04.175637+00	\N	4	bhj	100.00	155	unavailable	40h5794	\N
401	2024-11-22 01:43:48.243584+00	2024-11-27 03:26:08.714804+00	\N	4	ko	100.00	4	available	50H123457	\N
437	2024-11-27 03:43:13.5872+00	2024-11-27 03:43:13.5872+00	\N	4	a	10.00	160	driverless	50H-123450	\N
438	2024-11-27 03:44:55.225343+00	2024-11-27 03:44:55.225343+00	\N	4	a	10.00	160	driverless	50H-123451	\N
440	2024-11-30 22:08:25.653115+00	2024-12-02 04:01:25.20898+00	\N	4	ko	50.00	161	available	27H-99990	\N
434	2024-11-26 06:34:50.095535+00	2024-11-26 06:36:03.602909+00	\N	4	hjkk	50.00	155	available	40h5567	\N
413	2024-11-22 07:19:34.100319+00	2024-12-01 02:09:04.382495+00	\N	4	bjj	50.00	155	unavailable	40h3659	\N
436	2024-11-26 07:46:22.005217+00	2024-11-27 04:15:02.379235+00	\N	4	yhhu	50.00	160	available	60h4897	\N
441	2024-12-02 04:02:02.834844+00	2024-12-02 04:03:57.20614+00	\N	4	bnn	50.00	162	available	60h3498	\N
428	2024-11-25 04:20:29.138727+00	2024-11-28 04:01:12.723595+00	\N	4	vnn	50.00	155	unavailable	50h6783	\N
429	2024-11-25 04:22:48.424157+00	2024-11-28 04:01:12.933282+00	\N	4	dff	50.00	155	unavailable	50h5677	\N
442	2024-12-02 04:02:41.432412+00	2024-12-02 04:05:19.289332+00	\N	4	bbn	50.00	162	available	60h7899	\N
439	2024-11-30 21:58:18.000737+00	2024-11-30 21:59:19.667794+00	\N	4	ko	50.00	120	available	50H-98179	\N
\.


--
-- Name: accounting_vouchers_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.accounting_vouchers_id_seq1', 1, false);


--
-- Name: assigned_to_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.assigned_to_id_seq', 1, false);


--
-- Name: balances_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.balances_id_seq', 1, false);


--
-- Name: cancellation_drivers_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.cancellation_drivers_id_seq', 2, true);


--
-- Name: company_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.company_id_seq', 3, true);


--
-- Name: customer_address_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.customer_address_id_seq', 663, true);


--
-- Name: customer_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.customer_id_seq', 2, true);


--
-- Name: customer_products_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.customer_products_id_seq', 455, true);


--
-- Name: customer_routes_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.customer_routes_id_seq', 97, true);


--
-- Name: customers_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.customers_id_seq', 899, true);


--
-- Name: delivery_order_details_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.delivery_order_details_id_seq1', 1, false);


--
-- Name: delivery_orders_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.delivery_orders_id_seq1', 1, false);


--
-- Name: department_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.department_id_seq', 9, true);


--
-- Name: drivers_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.drivers_id_seq', 182, true);


--
-- Name: driving_car_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.driving_car_id_seq', 83, true);


--
-- Name: driving_car_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.driving_car_id_seq1', 2, true);


--
-- Name: formulas_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.formulas_id_seq', 3, true);


--
-- Name: internal_customer_address_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.internal_customer_address_id_seq', 54, true);


--
-- Name: internal_customer_good_type_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.internal_customer_good_type_id_seq', 63, true);


--
-- Name: internal_customer_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.internal_customer_id_seq', 50, true);


--
-- Name: internal_good_type_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.internal_good_type_id_seq', 18, true);


--
-- Name: internal_order_media_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.internal_order_media_id_seq', 4, true);


--
-- Name: internal_orders_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.internal_orders_id_seq', 84, true);


--
-- Name: internal_warehouse_good_type_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.internal_warehouse_good_type_id_seq', 9, true);


--
-- Name: internal_warehouse_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.internal_warehouse_id_seq', 7, true);


--
-- Name: inventory_products_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.inventory_products_id_seq1', 1, false);


--
-- Name: managers_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.managers_id_seq', 1, false);


--
-- Name: media_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.media_id_seq', 799, true);


--
-- Name: object_images_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.object_images_id_seq', 1555, true);


--
-- Name: operators_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.operators_id_seq', 1, false);


--
-- Name: order_customer_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.order_customer_id_seq', 18, true);


--
-- Name: order_customer_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.order_customer_id_seq1', 23, true);


--
-- Name: orders_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.orders_id_seq', 764, true);


--
-- Name: owner_car_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.owner_car_id_seq', 1, false);


--
-- Name: owner_car_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.owner_car_id_seq1', 5, true);


--
-- Name: payment_informations_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.payment_informations_id_seq', 1, false);


--
-- Name: permission_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.permission_id_seq', 1, false);


--
-- Name: products_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.products_id_seq', 181, true);


--
-- Name: products_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.products_id_seq1', 1, false);


--
-- Name: purchase_proposal_details_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.purchase_proposal_details_id_seq1', 1, false);


--
-- Name: purchase_proposals_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.purchase_proposals_id_seq1', 1, false);


--
-- Name: ratings_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.ratings_id_seq', 1, false);


--
-- Name: receipt_details_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.receipt_details_id_seq1', 1, false);


--
-- Name: receipts_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.receipts_id_seq1', 1, false);


--
-- Name: role_departments_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.role_departments_id_seq', 20, true);


--
-- Name: role_hierarchies_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.role_hierarchies_id_seq', 5, true);


--
-- Name: role_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.role_id_seq', 25, true);


--
-- Name: role_permission_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.role_permission_id_seq', 1, false);


--
-- Name: suppliers_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.suppliers_id_seq', 1, false);


--
-- Name: task_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.task_id_seq', 1, false);


--
-- Name: task_process_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.task_process_id_seq', 1, false);


--
-- Name: transactions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.transactions_id_seq', 567, true);


--
-- Name: truck_car_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.truck_car_id_seq', 29, true);


--
-- Name: truck_car_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.truck_car_id_seq1', 9, true);


--
-- Name: truck_components_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.truck_components_id_seq', 2, true);


--
-- Name: user_department_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.user_department_id_seq', 21, true);


--
-- Name: user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.user_id_seq', 143, true);


--
-- Name: user_role_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.user_role_id_seq', 26, true);


--
-- Name: users_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.users_id_seq', 1, false);


--
-- Name: users_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.users_id_seq1', 1, false);


--
-- Name: variables_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.variables_id_seq', 8, true);


--
-- Name: vehicle_types_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.vehicle_types_id_seq', 162, true);


--
-- Name: vehicles_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.vehicles_id_seq', 442, true);


--
-- Name: warehouses_id_seq; Type: SEQUENCE SET; Schema: public; Owner: root
--

SELECT pg_catalog.setval('public.warehouses_id_seq', 1, false);


--
-- Name: assigned_to assigned_to_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.assigned_to
    ADD CONSTRAINT assigned_to_pkey PRIMARY KEY (id);


--
-- Name: company company_company_code_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.company
    ADD CONSTRAINT company_company_code_key UNIQUE (company_code);


--
-- Name: company company_name_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.company
    ADD CONSTRAINT company_name_key UNIQUE (name);


--
-- Name: company company_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.company
    ADD CONSTRAINT company_pkey PRIMARY KEY (id);


--
-- Name: customer_address customer_address_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.customer_address
    ADD CONSTRAINT customer_address_pkey PRIMARY KEY (id);


--
-- Name: customer_products customer_products_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.customer_products
    ADD CONSTRAINT customer_products_pkey PRIMARY KEY (id);


--
-- Name: customer_routes customer_routes_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.customer_routes
    ADD CONSTRAINT customer_routes_pkey PRIMARY KEY (id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: department department_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.department
    ADD CONSTRAINT department_pkey PRIMARY KEY (id);


--
-- Name: drivers drivers_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.drivers
    ADD CONSTRAINT drivers_pkey PRIMARY KEY (id);


--
-- Name: driving_car driving_car_driving_license_back_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.driving_car
    ADD CONSTRAINT driving_car_driving_license_back_key UNIQUE (driving_license_back);


--
-- Name: driving_car driving_car_driving_license_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.driving_car
    ADD CONSTRAINT driving_car_driving_license_key UNIQUE (driving_license);


--
-- Name: driving_car driving_car_driving_phone_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.driving_car
    ADD CONSTRAINT driving_car_driving_phone_key UNIQUE (driving_phone);


--
-- Name: driving_car driving_car_email_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.driving_car
    ADD CONSTRAINT driving_car_email_key UNIQUE (email);


--
-- Name: driving_car driving_car_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.driving_car
    ADD CONSTRAINT driving_car_pkey PRIMARY KEY (id);


--
-- Name: formulas formulas_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.formulas
    ADD CONSTRAINT formulas_pkey PRIMARY KEY (id);


--
-- Name: internal_customer_address internal_customer_address_address_phone_number_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_customer_address
    ADD CONSTRAINT internal_customer_address_address_phone_number_key UNIQUE (address_phone_number);


--
-- Name: internal_customer_address internal_customer_address_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_customer_address
    ADD CONSTRAINT internal_customer_address_pkey PRIMARY KEY (id);


--
-- Name: internal_customer internal_customer_email_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_customer
    ADD CONSTRAINT internal_customer_email_key UNIQUE (email);


--
-- Name: internal_customer_good_type internal_customer_good_type_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_customer_good_type
    ADD CONSTRAINT internal_customer_good_type_pkey PRIMARY KEY (internal_good_type_id, internal_customer_id);


--
-- Name: internal_customer internal_customer_phone_number_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_customer
    ADD CONSTRAINT internal_customer_phone_number_key UNIQUE (phone_number);


--
-- Name: internal_customer internal_customer_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_customer
    ADD CONSTRAINT internal_customer_pkey PRIMARY KEY (id);


--
-- Name: internal_customer internal_customer_tax_code_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_customer
    ADD CONSTRAINT internal_customer_tax_code_key UNIQUE (tax_code);


--
-- Name: internal_good_type internal_good_type_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_good_type
    ADD CONSTRAINT internal_good_type_pkey PRIMARY KEY (id);


--
-- Name: internal_order_media internal_order_media_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_order_media
    ADD CONSTRAINT internal_order_media_pkey PRIMARY KEY (id);


--
-- Name: internal_orders internal_orders_order_code_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_orders
    ADD CONSTRAINT internal_orders_order_code_key UNIQUE (order_code);


--
-- Name: internal_orders internal_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_orders
    ADD CONSTRAINT internal_orders_pkey PRIMARY KEY (id);


--
-- Name: internal_warehouse_good_type internal_warehouse_good_type_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_warehouse_good_type
    ADD CONSTRAINT internal_warehouse_good_type_pkey PRIMARY KEY (internal_good_type_id, internal_warehouse_id);


--
-- Name: internal_warehouse internal_warehouse_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_warehouse
    ADD CONSTRAINT internal_warehouse_pkey PRIMARY KEY (id);


--
-- Name: managers managers_cccd_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.managers
    ADD CONSTRAINT managers_cccd_key UNIQUE (cccd);


--
-- Name: managers managers_email_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.managers
    ADD CONSTRAINT managers_email_key UNIQUE (email);


--
-- Name: managers managers_phone_number_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.managers
    ADD CONSTRAINT managers_phone_number_key UNIQUE (phone_number);


--
-- Name: managers managers_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.managers
    ADD CONSTRAINT managers_pkey PRIMARY KEY (id);


--
-- Name: media media_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.media
    ADD CONSTRAINT media_pkey PRIMARY KEY (id);


--
-- Name: migrations migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.migrations
    ADD CONSTRAINT migrations_pkey PRIMARY KEY (id);


--
-- Name: object_images object_images_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.object_images
    ADD CONSTRAINT object_images_pkey PRIMARY KEY (id);


--
-- Name: operators operators_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.operators
    ADD CONSTRAINT operators_pkey PRIMARY KEY (id);


--
-- Name: order_customer order_customer_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.order_customer
    ADD CONSTRAINT order_customer_pkey PRIMARY KEY (id);


--
-- Name: order_customer order_customer_pre_order_id_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.order_customer
    ADD CONSTRAINT order_customer_pre_order_id_key UNIQUE (pre_order_id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: owner_car owner_car_cccd_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.owner_car
    ADD CONSTRAINT owner_car_cccd_key UNIQUE (cccd);


--
-- Name: owner_car owner_car_email_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.owner_car
    ADD CONSTRAINT owner_car_email_key UNIQUE (email);


--
-- Name: owner_car owner_car_phone_number_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.owner_car
    ADD CONSTRAINT owner_car_phone_number_key UNIQUE (phone_number);


--
-- Name: owner_car owner_car_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.owner_car
    ADD CONSTRAINT owner_car_pkey PRIMARY KEY (id);


--
-- Name: permission permission_permission_name_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.permission
    ADD CONSTRAINT permission_permission_name_key UNIQUE (permission_name);


--
-- Name: permission permission_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.permission
    ADD CONSTRAINT permission_pkey PRIMARY KEY (id);


--
-- Name: product_vehicle_types product_vehicle_types_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.product_vehicle_types
    ADD CONSTRAINT product_vehicle_types_pkey PRIMARY KEY (product_id, vehicle_type_id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: ratings ratings_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.ratings
    ADD CONSTRAINT ratings_pkey PRIMARY KEY (id);


--
-- Name: role_departments role_departments_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.role_departments
    ADD CONSTRAINT role_departments_pkey PRIMARY KEY (id);


--
-- Name: role_hierarchies role_hierarchies_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.role_hierarchies
    ADD CONSTRAINT role_hierarchies_pkey PRIMARY KEY (id);


--
-- Name: role_permission role_permission_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.role_permission
    ADD CONSTRAINT role_permission_pkey PRIMARY KEY (id);


--
-- Name: role role_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_pkey PRIMARY KEY (id);


--
-- Name: role role_role_name_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_role_name_key UNIQUE (role_name);


--
-- Name: task task_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.task
    ADD CONSTRAINT task_pkey PRIMARY KEY (id);


--
-- Name: task_process task_process_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.task_process
    ADD CONSTRAINT task_process_pkey PRIMARY KEY (id);


--
-- Name: transactions transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.transactions
    ADD CONSTRAINT transactions_pkey PRIMARY KEY (id);


--
-- Name: truck_car truck_car_license_car_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.truck_car
    ADD CONSTRAINT truck_car_license_car_key UNIQUE (license_car);


--
-- Name: truck_car truck_car_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.truck_car
    ADD CONSTRAINT truck_car_pkey PRIMARY KEY (id);


--
-- Name: truck_components truck_components_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.truck_components
    ADD CONSTRAINT truck_components_pkey PRIMARY KEY (id);


--
-- Name: customer_address uni_customer_address_address_phone_number; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.customer_address
    ADD CONSTRAINT uni_customer_address_address_phone_number UNIQUE (address_phone_number);


--
-- Name: customers uni_customers_email; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT uni_customers_email UNIQUE (email);


--
-- Name: customers uni_customers_phone_number; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT uni_customers_phone_number UNIQUE (phone_number);


--
-- Name: customers uni_customers_tax_code; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT uni_customers_tax_code UNIQUE (tax_code);


--
-- Name: drivers uni_drivers_email; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.drivers
    ADD CONSTRAINT uni_drivers_email UNIQUE (email);


--
-- Name: drivers uni_drivers_phone_number; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.drivers
    ADD CONSTRAINT uni_drivers_phone_number UNIQUE (phone_number);


--
-- Name: orders uni_orders_order_code; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT uni_orders_order_code UNIQUE (order_code);


--
-- Name: vehicle_types uni_vehicle_types_type_name; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.vehicle_types
    ADD CONSTRAINT uni_vehicle_types_type_name UNIQUE (type_name);


--
-- Name: vehicles uni_vehicles_additional_plate; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.vehicles
    ADD CONSTRAINT uni_vehicles_additional_plate UNIQUE (additional_plate);


--
-- Name: vehicles uni_vehicles_vehicle_plate; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.vehicles
    ADD CONSTRAINT uni_vehicles_vehicle_plate UNIQUE (vehicle_plate);


--
-- Name: user user_citizen_identity_card_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public."user"
    ADD CONSTRAINT user_citizen_identity_card_key UNIQUE (citizen_identity_card);


--
-- Name: user_department user_department_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.user_department
    ADD CONSTRAINT user_department_pkey PRIMARY KEY (id);


--
-- Name: user user_email_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public."user"
    ADD CONSTRAINT user_email_key UNIQUE (email);


--
-- Name: user user_phone_number_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public."user"
    ADD CONSTRAINT user_phone_number_key UNIQUE (phone_number);


--
-- Name: user user_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public."user"
    ADD CONSTRAINT user_pkey PRIMARY KEY (id);


--
-- Name: user_role user_role_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.user_role
    ADD CONSTRAINT user_role_pkey PRIMARY KEY (id);


--
-- Name: user user_user_name_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public."user"
    ADD CONSTRAINT user_user_name_key UNIQUE (user_name);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: users users_user_name_key; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_user_name_key UNIQUE (user_name);


--
-- Name: variables variables_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.variables
    ADD CONSTRAINT variables_pkey PRIMARY KEY (id);


--
-- Name: vehicle_types vehicle_types_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.vehicle_types
    ADD CONSTRAINT vehicle_types_pkey PRIMARY KEY (id);


--
-- Name: vehicles vehicles_pkey; Type: CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.vehicles
    ADD CONSTRAINT vehicles_pkey PRIMARY KEY (id);


--
-- Name: idx_assigned_to_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_assigned_to_deleted_at ON public.assigned_to USING btree (deleted_at);


--
-- Name: idx_cancellation_drivers_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_cancellation_drivers_deleted_at ON public.cancellation_drivers USING btree (deleted_at);


--
-- Name: idx_company_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_company_deleted_at ON public.company USING btree (deleted_at);


--
-- Name: idx_customer_address_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_customer_address_deleted_at ON public.customer_address USING btree (deleted_at);


--
-- Name: idx_customer_products_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_customer_products_deleted_at ON public.customer_products USING btree (deleted_at);


--
-- Name: idx_customer_routes_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_customer_routes_deleted_at ON public.customer_routes USING btree (deleted_at);


--
-- Name: idx_customers_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_customers_deleted_at ON public.customers USING btree (deleted_at);


--
-- Name: idx_department_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_department_deleted_at ON public.department USING btree (deleted_at);


--
-- Name: idx_drivers_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_drivers_deleted_at ON public.drivers USING btree (deleted_at);


--
-- Name: idx_drivers_vehicle_id; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_drivers_vehicle_id ON public.drivers USING btree (vehicle_id);


--
-- Name: idx_driving_car_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_driving_car_deleted_at ON public.driving_car USING btree (deleted_at);


--
-- Name: idx_driving_car_driving_license; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_driving_car_driving_license ON public.driving_car USING btree (driving_license);


--
-- Name: idx_driving_car_driving_phone; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_driving_car_driving_phone ON public.driving_car USING btree (driving_phone);


--
-- Name: idx_driving_car_email; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_driving_car_email ON public.driving_car USING btree (email);


--
-- Name: idx_formulas_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_formulas_deleted_at ON public.formulas USING btree (deleted_at);


--
-- Name: idx_internal_customer_address_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_internal_customer_address_deleted_at ON public.internal_customer_address USING btree (deleted_at);


--
-- Name: idx_internal_customer_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_internal_customer_deleted_at ON public.internal_customer USING btree (deleted_at);


--
-- Name: idx_internal_customer_good_type_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_internal_customer_good_type_deleted_at ON public.internal_customer_good_type USING btree (deleted_at);


--
-- Name: idx_internal_good_type_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_internal_good_type_deleted_at ON public.internal_good_type USING btree (deleted_at);


--
-- Name: idx_internal_order_media_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_internal_order_media_deleted_at ON public.internal_order_media USING btree (deleted_at);


--
-- Name: idx_internal_orders_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_internal_orders_deleted_at ON public.internal_orders USING btree (deleted_at);


--
-- Name: idx_internal_warehouse_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_internal_warehouse_deleted_at ON public.internal_warehouse USING btree (deleted_at);


--
-- Name: idx_internal_warehouse_good_type_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_internal_warehouse_good_type_deleted_at ON public.internal_warehouse_good_type USING btree (deleted_at);


--
-- Name: idx_managers_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_managers_deleted_at ON public.managers USING btree (deleted_at);


--
-- Name: idx_media_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_media_deleted_at ON public.media USING btree (deleted_at);


--
-- Name: idx_object_images_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_object_images_deleted_at ON public.object_images USING btree (deleted_at);


--
-- Name: idx_operators_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_operators_deleted_at ON public.operators USING btree (deleted_at);


--
-- Name: idx_order_customer_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_order_customer_deleted_at ON public.order_customer USING btree (deleted_at);


--
-- Name: idx_orders_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_orders_deleted_at ON public.orders USING btree (deleted_at);


--
-- Name: idx_owner_car_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_owner_car_deleted_at ON public.owner_car USING btree (deleted_at);


--
-- Name: idx_permission_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_permission_deleted_at ON public.permission USING btree (deleted_at);


--
-- Name: idx_products_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_products_deleted_at ON public.products USING btree (deleted_at);


--
-- Name: idx_public_cancellation_drivers_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_public_cancellation_drivers_deleted_at ON public.cancellation_drivers USING btree (deleted_at);


--
-- Name: idx_public_internal_orders_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_public_internal_orders_deleted_at ON public.internal_orders USING btree (deleted_at);


--
-- Name: idx_ratings_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_ratings_deleted_at ON public.ratings USING btree (deleted_at);


--
-- Name: idx_role_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_role_deleted_at ON public.role USING btree (deleted_at);


--
-- Name: idx_role_departments_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_role_departments_deleted_at ON public.role_departments USING btree (deleted_at);


--
-- Name: idx_role_hierarchies_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_role_hierarchies_deleted_at ON public.role_hierarchies USING btree (deleted_at);


--
-- Name: idx_role_permission_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_role_permission_deleted_at ON public.role_permission USING btree (deleted_at);


--
-- Name: idx_task_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_task_deleted_at ON public.task USING btree (deleted_at);


--
-- Name: idx_task_process_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_task_process_deleted_at ON public.task_process USING btree (deleted_at);


--
-- Name: idx_transactions_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_transactions_deleted_at ON public.transactions USING btree (deleted_at);


--
-- Name: idx_truck_car_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_truck_car_deleted_at ON public.truck_car USING btree (deleted_at);


--
-- Name: idx_truck_components_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_truck_components_deleted_at ON public.truck_components USING btree (deleted_at);


--
-- Name: idx_user_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_user_deleted_at ON public."user" USING btree (deleted_at);


--
-- Name: idx_user_department_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_user_department_deleted_at ON public.user_department USING btree (deleted_at);


--
-- Name: idx_user_role_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_user_role_deleted_at ON public.user_role USING btree (deleted_at);


--
-- Name: idx_variables_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_variables_deleted_at ON public.variables USING btree (deleted_at);


--
-- Name: idx_vehicle_types_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_vehicle_types_deleted_at ON public.vehicle_types USING btree (deleted_at);


--
-- Name: idx_vehicles_deleted_at; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_vehicles_deleted_at ON public.vehicles USING btree (deleted_at);


--
-- Name: idx_vehicles_owner_id; Type: INDEX; Schema: public; Owner: root
--

CREATE INDEX idx_vehicles_owner_id ON public.vehicles USING btree (owner_id);


--
-- Name: permission fk_company_permissions; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.permission
    ADD CONSTRAINT fk_company_permissions FOREIGN KEY (company_id) REFERENCES public.company(id);


--
-- Name: customer_address fk_customers_list_customer_address; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.customer_address
    ADD CONSTRAINT fk_customers_list_customer_address FOREIGN KEY (customer_id) REFERENCES public.customers(id);


--
-- Name: department fk_department_company; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.department
    ADD CONSTRAINT fk_department_company FOREIGN KEY (company_id) REFERENCES public.company(id);


--
-- Name: drivers fk_drivers_vehicle; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.drivers
    ADD CONSTRAINT fk_drivers_vehicle FOREIGN KEY (vehicle_id) REFERENCES public.vehicles(id);


--
-- Name: internal_customer_address fk_internal_customer_list_internal_customer_address; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_customer_address
    ADD CONSTRAINT fk_internal_customer_list_internal_customer_address FOREIGN KEY (internal_customer_id) REFERENCES public.internal_customer(id);


--
-- Name: internal_warehouse_good_type fk_internal_warehouse_good_type_internal_good_type; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_warehouse_good_type
    ADD CONSTRAINT fk_internal_warehouse_good_type_internal_good_type FOREIGN KEY (internal_good_type_id) REFERENCES public.internal_good_type(id);


--
-- Name: internal_warehouse_good_type fk_internal_warehouse_good_type_internal_warehouse; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_warehouse_good_type
    ADD CONSTRAINT fk_internal_warehouse_good_type_internal_warehouse FOREIGN KEY (internal_warehouse_id) REFERENCES public.internal_warehouse(id);


--
-- Name: managers fk_owner_car_manager; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.managers
    ADD CONSTRAINT fk_owner_car_manager FOREIGN KEY (owner_car_id) REFERENCES public.owner_car(id);


--
-- Name: permission fk_permission_company; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.permission
    ADD CONSTRAINT fk_permission_company FOREIGN KEY (company_id) REFERENCES public.company(id);


--
-- Name: product_vehicle_types fk_product_vehicle_types_product; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.product_vehicle_types
    ADD CONSTRAINT fk_product_vehicle_types_product FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: product_vehicle_types fk_product_vehicle_types_vehicle_type; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.product_vehicle_types
    ADD CONSTRAINT fk_product_vehicle_types_vehicle_type FOREIGN KEY (vehicle_type_id) REFERENCES public.vehicle_types(id) ON DELETE CASCADE;


--
-- Name: internal_customer_good_type fk_public_internal_customer_good_type_internal_customer; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_customer_good_type
    ADD CONSTRAINT fk_public_internal_customer_good_type_internal_customer FOREIGN KEY (internal_customer_id) REFERENCES public.internal_customer(id);


--
-- Name: internal_customer_good_type fk_public_internal_customer_good_type_internal_good_type; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_customer_good_type
    ADD CONSTRAINT fk_public_internal_customer_good_type_internal_good_type FOREIGN KEY (internal_good_type_id) REFERENCES public.internal_good_type(id);


--
-- Name: internal_warehouse_good_type fk_public_internal_warehouse_good_type_internal_good_type; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_warehouse_good_type
    ADD CONSTRAINT fk_public_internal_warehouse_good_type_internal_good_type FOREIGN KEY (internal_good_type_id) REFERENCES public.internal_good_type(id);


--
-- Name: internal_warehouse_good_type fk_public_internal_warehouse_good_type_internal_warehouse; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.internal_warehouse_good_type
    ADD CONSTRAINT fk_public_internal_warehouse_good_type_internal_warehouse FOREIGN KEY (internal_warehouse_id) REFERENCES public.internal_warehouse(id);


--
-- Name: role fk_role_company; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT fk_role_company FOREIGN KEY (company_id) REFERENCES public.company(id);


--
-- Name: role_departments fk_role_departments_department; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.role_departments
    ADD CONSTRAINT fk_role_departments_department FOREIGN KEY (department_id) REFERENCES public.department(id);


--
-- Name: role_departments fk_role_departments_role; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.role_departments
    ADD CONSTRAINT fk_role_departments_role FOREIGN KEY (role_id) REFERENCES public.role(id);


--
-- Name: role_permission fk_role_permission_company; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.role_permission
    ADD CONSTRAINT fk_role_permission_company FOREIGN KEY (company_id) REFERENCES public.company(id);


--
-- Name: role_permission fk_role_permission_permission; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.role_permission
    ADD CONSTRAINT fk_role_permission_permission FOREIGN KEY (permission_id) REFERENCES public.permission(id);


--
-- Name: role_permission fk_role_permission_role; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.role_permission
    ADD CONSTRAINT fk_role_permission_role FOREIGN KEY (role_id) REFERENCES public.role(id);


--
-- Name: assigned_to fk_task_assigned_to_user; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.assigned_to
    ADD CONSTRAINT fk_task_assigned_to_user FOREIGN KEY (task_id) REFERENCES public.task(id);


--
-- Name: task fk_task_company; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.task
    ADD CONSTRAINT fk_task_company FOREIGN KEY (company_id) REFERENCES public.company(id);


--
-- Name: task fk_task_department; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.task
    ADD CONSTRAINT fk_task_department FOREIGN KEY (department_id) REFERENCES public.department(id);


--
-- Name: task_process fk_task_task_process; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.task_process
    ADD CONSTRAINT fk_task_task_process FOREIGN KEY (task_id) REFERENCES public.task(id);


--
-- Name: user fk_user_company; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public."user"
    ADD CONSTRAINT fk_user_company FOREIGN KEY (company_id) REFERENCES public.company(id);


--
-- Name: user_department fk_user_department_company; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.user_department
    ADD CONSTRAINT fk_user_department_company FOREIGN KEY (company_id) REFERENCES public.company(id);


--
-- Name: user_department fk_user_department_department; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.user_department
    ADD CONSTRAINT fk_user_department_department FOREIGN KEY (department_id) REFERENCES public.department(id);


--
-- Name: user_department fk_user_department_user; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.user_department
    ADD CONSTRAINT fk_user_department_user FOREIGN KEY (user_id) REFERENCES public."user"(id);


--
-- Name: user_role fk_user_role_company; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.user_role
    ADD CONSTRAINT fk_user_role_company FOREIGN KEY (company_id) REFERENCES public.company(id);


--
-- Name: user_role fk_user_role_role; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.user_role
    ADD CONSTRAINT fk_user_role_role FOREIGN KEY (role_id) REFERENCES public.role(id);


--
-- Name: user_role fk_user_role_user; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.user_role
    ADD CONSTRAINT fk_user_role_user FOREIGN KEY (user_id) REFERENCES public."user"(id);


--
-- Name: task fk_user_tasks_assigned; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.task
    ADD CONSTRAINT fk_user_tasks_assigned FOREIGN KEY (assigned_by) REFERENCES public."user"(id);


--
-- Name: assigned_to fk_user_tasks_received; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.assigned_to
    ADD CONSTRAINT fk_user_tasks_received FOREIGN KEY (user_id) REFERENCES public."user"(id);


--
-- Name: products fk_vehicle_types_product; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT fk_vehicle_types_product FOREIGN KEY (vehicle_type_id) REFERENCES public.vehicle_types(id);


--
-- Name: vehicles fk_vehicles_vehicle_type; Type: FK CONSTRAINT; Schema: public; Owner: root
--

ALTER TABLE ONLY public.vehicles
    ADD CONSTRAINT fk_vehicles_vehicle_type FOREIGN KEY (vehicle_type_id) REFERENCES public.vehicle_types(id);


--
-- PostgreSQL database dump complete
--

