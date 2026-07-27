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

--
-- Name: folio_ledger_events_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.folio_ledger_events_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION
    'ledger_events is append-only: % on row id=% rejected',
    TG_OP, COALESCE(OLD.id, NEW.id)
    USING ERRCODE = 'restrict_violation';
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ledger_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ledger_events (
    id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    office_id bigint,
    seq bigint NOT NULL,
    actor_user_id bigint,
    signature bytea,
    recorded_at timestamp(6) without time zone DEFAULT clock_timestamp() NOT NULL,
    prev_hash character varying(64) NOT NULL,
    hash_hex character varying(64) NOT NULL,
    hash_version integer DEFAULT 2 NOT NULL,
    ts character varying NOT NULL,
    actor character varying NOT NULL,
    action character varying NOT NULL,
    ref character varying,
    origin character varying NOT NULL,
    payload text NOT NULL
);


--
-- Name: ledger_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ledger_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ledger_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ledger_events_id_seq OWNED BY public.ledger_events.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: ledger_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_events ALTER COLUMN id SET DEFAULT nextval('public.ledger_events_id_seq'::regclass);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: ledger_events ledger_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ledger_events
    ADD CONSTRAINT ledger_events_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: index_ledger_events_on_tenant_id_and_action; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ledger_events_on_tenant_id_and_action ON public.ledger_events USING btree (tenant_id, action);


--
-- Name: index_ledger_events_on_tenant_id_and_hash_hex; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ledger_events_on_tenant_id_and_hash_hex ON public.ledger_events USING btree (tenant_id, hash_hex);


--
-- Name: index_ledger_events_on_tenant_id_and_office_id_and_seq; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ledger_events_on_tenant_id_and_office_id_and_seq ON public.ledger_events USING btree (tenant_id, office_id, seq);


--
-- Name: index_ledger_events_on_tenant_id_and_seq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ledger_events_on_tenant_id_and_seq ON public.ledger_events USING btree (tenant_id, seq);


--
-- Name: ledger_events ledger_events_no_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ledger_events_no_delete BEFORE DELETE ON public.ledger_events FOR EACH ROW EXECUTE FUNCTION public.folio_ledger_events_append_only();


--
-- Name: ledger_events ledger_events_no_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ledger_events_no_truncate BEFORE TRUNCATE ON public.ledger_events FOR EACH STATEMENT EXECUTE FUNCTION public.folio_ledger_events_append_only();


--
-- Name: ledger_events ledger_events_no_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ledger_events_no_update BEFORE UPDATE ON public.ledger_events FOR EACH ROW EXECUTE FUNCTION public.folio_ledger_events_append_only();


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260727214500');

