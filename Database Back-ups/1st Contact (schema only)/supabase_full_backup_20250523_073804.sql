

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






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."verification_status_enum" AS ENUM (
    'pending',
    'approved',
    'rejected',
    'requires_info'
);


ALTER TYPE "public"."verification_status_enum" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_user_email_data"() RETURNS TABLE("id" "uuid", "email" "text", "role" "text", "first_name" "text", "last_name" "text", "subscription_type" "text", "TherapistProfileStarted" "text", "TipTerapie" "text"[], "RegularPrice" numeric)
    LANGUAGE "plpgsql" STABLE
    AS $$
BEGIN
  -- Ensure only authorized users can call this (as discussed before, RLS or function security)
  RETURN QUERY
  SELECT
    p.id,
    p.email,
    p.role,
    p.first_name,
    p.last_name,
    p.subscription_type,
    CASE WHEN tp.id IS NULL THEN 'No' ELSE 'Yes' END AS "TherapistProfileStarted",
    tp.therapy_types AS "TipTerapie", -- This will now correctly return a TEXT[] if tp.therapy_types is TEXT[]
    tp.price_per_session AS "RegularPrice"
  FROM public.profiles p
  LEFT JOIN public.therapist_profiles tp ON tp.id = p.id;
END;
$$;


ALTER FUNCTION "public"."get_admin_user_email_data"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_news_feed_posts_with_details"("p_current_user_id" "uuid" DEFAULT NULL::"uuid") RETURNS SETOF "json"
    LANGUAGE "sql" STABLE
    AS $$
SELECT
    json_build_object(
        'id', p.id,
        'authorName', 'Terapie Acasă', -- Hardcoded
        'authorAvatarUrl', '/logo.png', -- Hardcoded
        'content', p.content,
        'postedAt', p.posted_at::text, -- Cast to text to ensure consistent format
        'likesCount', (SELECT COUNT(*) FROM public.news_feed_likes l WHERE l.post_id = p.id),
        'currentUserHasLiked', CASE
            WHEN p_current_user_id IS NOT NULL THEN
                EXISTS(SELECT 1 FROM public.news_feed_likes l WHERE l.post_id = p.id AND l.user_id = p_current_user_id)
            ELSE
                false
        END,
        'comments', (
            SELECT COALESCE(json_agg(
                json_build_object(
                    'id', c.id,
                    'postId', c.post_id,
                    'content', c.content,
                    'createdAt', c.created_at::text, -- Cast to text
                    'authorProfile', get_user_profile_details(c.user_id)
                ) ORDER BY c.created_at ASC
            ), '[]'::json)
            FROM public.news_feed_comments c
            WHERE c.post_id = p.id
        )
    )
FROM
    public.news_feed_posts p
ORDER BY
    p.posted_at DESC;
$$;


ALTER FUNCTION "public"."get_news_feed_posts_with_details"("p_current_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_profile_details"("p_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_profile_record record; -- To store the row from the 'profiles' table
  v_therapist_profile_image text;
  v_therapist_first_type text;
  v_full_name text;
BEGIN
  -- 1. Fetch basic profile information from the 'profiles' table
  SELECT *
  INTO v_profile_record
  FROM public.profiles pr
  WHERE pr.id = p_user_id; -- p_user_id is the user's auth.users.id / profiles.id

  -- 2. Handle cases where the profile might not exist
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'id', p_user_id,
      'name', 'Utilizator Anonim',
      'role', null,
      'avatarUrl', null,
      'therapistType', null
    );
  END IF;

  -- 3. Construct full name
  v_full_name := TRIM(BOTH FROM COALESCE(
                        v_profile_record.first_name || ' ' || v_profile_record.last_name, 
                        v_profile_record.first_name, 
                        v_profile_record.last_name, 
                        SPLIT_PART(v_profile_record.email, '@', 1),
                        'Utilizator Necunoscut'
                      ));
  IF v_full_name = '' THEN
    v_full_name := SPLIT_PART(v_profile_record.email, '@', 1);
    IF v_full_name = '' THEN
        v_full_name := 'Utilizator Necunoscut';
    END IF;
  END IF;

  -- 4. Initialize therapist-specific details to null
  v_therapist_profile_image := null;
  v_therapist_first_type := null;

  -- 5. If the user's role is 'terapeut', fetch additional details from 'therapist_profiles'
  IF v_profile_record.role = 'terapeut' THEN
    SELECT
        tp.profile_image,
        (CASE
            WHEN array_length(tp.therapy_types, 1) > 0 THEN tp.therapy_types[1]
            ELSE NULL
        END)
    INTO v_therapist_profile_image, v_therapist_first_type
    FROM public.therapist_profiles tp
    WHERE tp.id = p_user_id; -- <<<<< CORRECTED LINE: Use tp.id to match p_user_id (profiles.id)

  END IF;

  -- 6. Return the combined profile information
  RETURN jsonb_build_object(
    'id', v_profile_record.id,
    'name', v_full_name,
    'role', v_profile_record.role,
    'avatarUrl', v_therapist_profile_image,
    'therapistType', v_therapist_first_type
  );
END;
$$;


ALTER FUNCTION "public"."get_user_profile_details"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  INSERT INTO public.profiles (id, email, role)
  VALUES (NEW.id, NEW.email, 'pending');
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reset_all_user_daily_ai_credits"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE public.profiles
  SET daily_ai_message_credits = daily_ai_msg_limit_max
  WHERE daily_ai_msg_limit_max IS NOT NULL AND daily_ai_msg_limit_max > 0; -- Or any other condition
END;
$$;


ALTER FUNCTION "public"."reset_all_user_daily_ai_credits"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_set_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trigger_set_timestamp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_conversation_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE public.ai_conversations
  SET updated_at = now()
  WHERE id = NEW.conversation_id;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_conversation_timestamp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_modified_column"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_modified_column"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_subscription_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    IF OLD.subscription_type IS DISTINCT FROM NEW.subscription_type THEN
        NEW.subscribed_at = NOW();
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_subscription_timestamp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."ai_conversations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "model_id" "text" NOT NULL,
    "last_message_snippet" "text"
);


ALTER TABLE "public"."ai_conversations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ai_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "conversation_id" "uuid" NOT NULL,
    "content" "text" NOT NULL,
    "sender" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ai_messages_sender_check" CHECK (("sender" = ANY (ARRAY['user'::"text", 'ai'::"text"])))
);


ALTER TABLE "public"."ai_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."appointments" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "client_id" "uuid",
    "therapist_id" "uuid",
    "date" timestamp with time zone,
    "duration" integer,
    "status" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "appointments_status_check" CHECK (("status" = ANY (ARRAY['programat'::"text", 'anulat'::"text", 'finalizat'::"text"])))
);


ALTER TABLE "public"."appointments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."calendly_integrations" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "access_token" "text" NOT NULL,
    "refresh_token" "text" NOT NULL,
    "token_type" "text",
    "expires_at" timestamp with time zone,
    "scope" "text",
    "calendly_user_uri" "text",
    "calendly_organization_uri" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "calendly_scheduling_url" "text",
    "calendly_user_name" "text"
);


ALTER TABLE "public"."calendly_integrations" OWNER TO "postgres";


COMMENT ON COLUMN "public"."calendly_integrations"."user_id" IS 'Foreign key to the user in auth.users table.';



COMMENT ON COLUMN "public"."calendly_integrations"."access_token" IS 'Calendly API access token.';



COMMENT ON COLUMN "public"."calendly_integrations"."refresh_token" IS 'Calendly API refresh token.';



COMMENT ON COLUMN "public"."calendly_integrations"."expires_at" IS 'Timestamp when the access_token expires.';



COMMENT ON COLUMN "public"."calendly_integrations"."calendly_user_uri" IS 'URI of the user resource in Calendly API.';



COMMENT ON COLUMN "public"."calendly_integrations"."calendly_organization_uri" IS 'URI of the organization resource in Calendly API.';



COMMENT ON COLUMN "public"."calendly_integrations"."calendly_scheduling_url" IS 'Direct scheduling URL from Calendly for the user.';



COMMENT ON COLUMN "public"."calendly_integrations"."calendly_user_name" IS 'User''s name from Calendly.';



CREATE TABLE IF NOT EXISTS "public"."client_preferences" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "client_id" "uuid",
    "therapy_type" "text",
    "therapist_gender" "text",
    "therapist_age_group" "text",
    "other_preferences" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "progress" integer DEFAULT 0,
    "email" "text",
    "phone" "text",
    "confidential_mode" "text"
);


ALTER TABLE "public"."client_preferences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."news_feed_comments" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "post_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."news_feed_comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."news_feed_likes" (
    "post_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "like_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."news_feed_likes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."news_feed_posts" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "content" "text" NOT NULL,
    "posted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."news_feed_posts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "first_name" "text",
    "last_name" "text",
    "phone" "text",
    "role" "text" DEFAULT 'client'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "referred_by" "text",
    "subscription_type" "text" DEFAULT 'free'::"text",
    "subscribed_at" timestamp with time zone,
    "daily_ai_message_credits" integer DEFAULT 10,
    "daily_ai_msg_limit_max" integer DEFAULT 10,
    "admin_level" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "profiles_role_check" CHECK (("role" = ANY (ARRAY['client'::"text", 'terapeut'::"text", 'pending'::"text"]))),
    CONSTRAINT "profiles_subscription_type_check" CHECK (("subscription_type" = ANY (ARRAY['free'::"text", 'try'::"text", 'standard'::"text", 'plus'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."therapist_profiles" (
    "id" "uuid" NOT NULL,
    "specialization" "text"[],
    "description" "text",
    "experience" integer,
    "education" "text",
    "certifications" "text"[],
    "price_per_session" numeric(10,2),
    "available_hours" "jsonb",
    "rating" numeric(3,2),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "therapy_types" "text"[],
    "key_experience" "text",
    "profile_image" "text",
    "referral_code" "text",
    "is_verified" boolean DEFAULT false
);


ALTER TABLE "public"."therapist_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."therapist_verification_requests" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "id_document_path" "text" NOT NULL,
    "certificate_paths" "text"[] NOT NULL,
    "status" "public"."verification_status_enum" DEFAULT 'pending'::"public"."verification_status_enum" NOT NULL,
    "requested_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_at" timestamp with time zone,
    "reviewer_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "check_certificate_paths_not_empty" CHECK (("array_length"("certificate_paths", 1) > 0))
);


ALTER TABLE "public"."therapist_verification_requests" OWNER TO "postgres";


COMMENT ON COLUMN "public"."therapist_verification_requests"."user_id" IS 'The ID of the therapist user requesting verification.';



COMMENT ON COLUMN "public"."therapist_verification_requests"."id_document_path" IS 'Storage path for the ID document (e.g., passport, national ID).';



COMMENT ON COLUMN "public"."therapist_verification_requests"."certificate_paths" IS 'Array of storage paths for relevant professional certificates.';



COMMENT ON COLUMN "public"."therapist_verification_requests"."status" IS 'Current status of the verification request.';



COMMENT ON COLUMN "public"."therapist_verification_requests"."reviewer_notes" IS 'Feedback or notes from the admin reviewing the application.';



ALTER TABLE ONLY "public"."ai_conversations"
    ADD CONSTRAINT "ai_conversations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ai_messages"
    ADD CONSTRAINT "ai_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."calendly_integrations"
    ADD CONSTRAINT "calendly_integrations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."calendly_integrations"
    ADD CONSTRAINT "calendly_integrations_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."client_preferences"
    ADD CONSTRAINT "client_preferences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."news_feed_comments"
    ADD CONSTRAINT "news_feed_comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."news_feed_likes"
    ADD CONSTRAINT "news_feed_likes_like_id_pkey" PRIMARY KEY ("like_id");



ALTER TABLE ONLY "public"."news_feed_posts"
    ADD CONSTRAINT "news_feed_posts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."therapist_profiles"
    ADD CONSTRAINT "therapist_profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."therapist_profiles"
    ADD CONSTRAINT "therapist_profiles_referral_code_key" UNIQUE ("referral_code");



ALTER TABLE ONLY "public"."therapist_verification_requests"
    ADD CONSTRAINT "therapist_verification_requests_pkey" PRIMARY KEY ("id");



CREATE OR REPLACE TRIGGER "handle_calendly_integrations_updated_at" BEFORE UPDATE ON "public"."calendly_integrations" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "set_therapist_verification_requests_updated_at" BEFORE UPDATE ON "public"."therapist_verification_requests" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_set_timestamp"();



CREATE OR REPLACE TRIGGER "update_appointments_modtime" BEFORE UPDATE ON "public"."appointments" FOR EACH ROW EXECUTE FUNCTION "public"."update_modified_column"();



CREATE OR REPLACE TRIGGER "update_client_preferences_modtime" BEFORE UPDATE ON "public"."client_preferences" FOR EACH ROW EXECUTE FUNCTION "public"."update_modified_column"();



CREATE OR REPLACE TRIGGER "update_client_preferences_updated_at" BEFORE UPDATE ON "public"."client_preferences" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_conversation_timestamp" AFTER INSERT ON "public"."ai_messages" FOR EACH ROW EXECUTE FUNCTION "public"."update_conversation_timestamp"();



CREATE OR REPLACE TRIGGER "update_profiles_modtime" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."update_modified_column"();



CREATE OR REPLACE TRIGGER "update_subscription_timestamp" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."update_subscription_timestamp"();



CREATE OR REPLACE TRIGGER "update_therapist_profiles_modtime" BEFORE UPDATE ON "public"."therapist_profiles" FOR EACH ROW EXECUTE FUNCTION "public"."update_modified_column"();



ALTER TABLE ONLY "public"."ai_conversations"
    ADD CONSTRAINT "ai_conversations_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ai_messages"
    ADD CONSTRAINT "ai_messages_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "public"."ai_conversations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_therapist_id_fkey" FOREIGN KEY ("therapist_id") REFERENCES "public"."therapist_profiles"("id");



ALTER TABLE ONLY "public"."calendly_integrations"
    ADD CONSTRAINT "calendly_integrations_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."client_preferences"
    ADD CONSTRAINT "client_preferences_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."news_feed_comments"
    ADD CONSTRAINT "news_feed_comments_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."news_feed_posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."news_feed_comments"
    ADD CONSTRAINT "news_feed_comments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."news_feed_likes"
    ADD CONSTRAINT "news_feed_likes_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."news_feed_posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."therapist_profiles"
    ADD CONSTRAINT "therapist_profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."therapist_verification_requests"
    ADD CONSTRAINT "therapist_verification_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Admin can insert posts." ON "public"."news_feed_posts" FOR INSERT WITH CHECK (("auth"."role"() = 'service_role'::"text"));



CREATE POLICY "Admins can view all verification requests" ON "public"."therapist_verification_requests" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."admin_level" >= 1)))));



CREATE POLICY "Allow admins to update verification requests" ON "public"."therapist_verification_requests" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles"
  WHERE (("profiles"."id" = "auth"."uid"()) AND ("profiles"."admin_level" >= 1)))));



CREATE POLICY "Allow authenticated users to insert their own verification requ" ON "public"."therapist_verification_requests" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Allow authenticated users to read public Calendly details" ON "public"."calendly_integrations" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated users to view their own verification reques" ON "public"."therapist_verification_requests" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Allow users to select their own calendly integration" ON "public"."calendly_integrations" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Authenticated users can insert comments." ON "public"."news_feed_comments" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert/delete likes." ON "public"."news_feed_likes" TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Clienții pot actualiza propriile preferințe" ON "public"."client_preferences" FOR UPDATE USING (("auth"."uid"() = "client_id"));



CREATE POLICY "Clienții pot actualiza propriile programări" ON "public"."appointments" FOR UPDATE USING (("auth"."uid"() = "client_id"));



CREATE POLICY "Clienții pot insera programări" ON "public"."appointments" FOR INSERT WITH CHECK (("auth"."uid"() = "client_id"));



CREATE POLICY "Clienții pot insera propriile preferințe" ON "public"."client_preferences" FOR INSERT WITH CHECK (("auth"."uid"() = "client_id"));



CREATE POLICY "Clienții pot vedea propriile preferințe" ON "public"."client_preferences" FOR SELECT USING (("auth"."uid"() = "client_id"));



CREATE POLICY "Clienții pot vedea propriile programări" ON "public"."appointments" FOR SELECT USING (("auth"."uid"() = "client_id"));



CREATE POLICY "Public can view likes (for counts, though not directly queried " ON "public"."news_feed_likes" FOR SELECT USING (true);



CREATE POLICY "Public comments are viewable by everyone." ON "public"."news_feed_comments" FOR SELECT USING (true);



CREATE POLICY "Public posts are viewable by everyone." ON "public"."news_feed_posts" FOR SELECT USING (true);



CREATE POLICY "Public profiles are viewable by everyone" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "Terapeuții pot actualiza programările lor" ON "public"."appointments" FOR UPDATE USING (("auth"."uid"() = "therapist_id"));



CREATE POLICY "Terapeuții pot actualiza propriul profil" ON "public"."therapist_profiles" FOR UPDATE USING (("auth"."uid"() = "id"));



CREATE POLICY "Terapeuții pot vedea programările lor" ON "public"."appointments" FOR SELECT USING (("auth"."uid"() = "therapist_id"));



CREATE POLICY "Terapeuții pot vedea propriul profil" ON "public"."therapist_profiles" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Toți utilizatorii pot vedea profilurile terapeuților" ON "public"."therapist_profiles" FOR SELECT USING (true);



CREATE POLICY "Users can delete their own comments." ON "public"."news_feed_comments" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own conversations" ON "public"."ai_conversations" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert messages to their conversations" ON "public"."ai_messages" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."ai_conversations"
  WHERE (("ai_conversations"."id" = "ai_messages"."conversation_id") AND ("ai_conversations"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can insert or update their own preferences" ON "public"."client_preferences" FOR UPDATE TO "authenticated" WITH CHECK (("auth"."uid"() = "client_id"));



CREATE POLICY "Users can insert their own conversations" ON "public"."ai_conversations" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own preferences" ON "public"."client_preferences" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "client_id"));



CREATE POLICY "Users can insert their own profile" ON "public"."profiles" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can read their own preferences" ON "public"."client_preferences" FOR SELECT USING (("auth"."uid"() = "client_id"));



CREATE POLICY "Users can update their own comments." ON "public"."news_feed_comments" FOR UPDATE USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own conversations" ON "public"."ai_conversations" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own profile" ON "public"."profiles" FOR UPDATE USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can view messages from their conversations" ON "public"."ai_messages" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."ai_conversations"
  WHERE (("ai_conversations"."id" = "ai_messages"."conversation_id") AND ("ai_conversations"."user_id" = "auth"."uid"())))));



CREATE POLICY "Users can view their own conversations" ON "public"."ai_conversations" FOR SELECT USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."ai_conversations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ai_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."appointments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."calendly_integrations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_preferences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."news_feed_comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."news_feed_likes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."news_feed_posts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."therapist_verification_requests" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";





GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";
































































































































































































GRANT ALL ON FUNCTION "public"."get_admin_user_email_data"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_admin_user_email_data"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_user_email_data"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_news_feed_posts_with_details"("p_current_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_news_feed_posts_with_details"("p_current_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_news_feed_posts_with_details"("p_current_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_profile_details"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_profile_details"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_profile_details"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."reset_all_user_daily_ai_credits"() TO "anon";
GRANT ALL ON FUNCTION "public"."reset_all_user_daily_ai_credits"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."reset_all_user_daily_ai_credits"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_set_timestamp"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_set_timestamp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_set_timestamp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_conversation_timestamp"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_conversation_timestamp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_conversation_timestamp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_modified_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_modified_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_modified_column"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_subscription_timestamp"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_subscription_timestamp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_subscription_timestamp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";
























GRANT ALL ON TABLE "public"."ai_conversations" TO "anon";
GRANT ALL ON TABLE "public"."ai_conversations" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_conversations" TO "service_role";



GRANT ALL ON TABLE "public"."ai_messages" TO "anon";
GRANT ALL ON TABLE "public"."ai_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."ai_messages" TO "service_role";



GRANT ALL ON TABLE "public"."appointments" TO "anon";
GRANT ALL ON TABLE "public"."appointments" TO "authenticated";
GRANT ALL ON TABLE "public"."appointments" TO "service_role";



GRANT ALL ON TABLE "public"."calendly_integrations" TO "anon";
GRANT ALL ON TABLE "public"."calendly_integrations" TO "authenticated";
GRANT ALL ON TABLE "public"."calendly_integrations" TO "service_role";



GRANT ALL ON TABLE "public"."client_preferences" TO "anon";
GRANT ALL ON TABLE "public"."client_preferences" TO "authenticated";
GRANT ALL ON TABLE "public"."client_preferences" TO "service_role";



GRANT ALL ON TABLE "public"."news_feed_comments" TO "anon";
GRANT ALL ON TABLE "public"."news_feed_comments" TO "authenticated";
GRANT ALL ON TABLE "public"."news_feed_comments" TO "service_role";



GRANT ALL ON TABLE "public"."news_feed_likes" TO "anon";
GRANT ALL ON TABLE "public"."news_feed_likes" TO "authenticated";
GRANT ALL ON TABLE "public"."news_feed_likes" TO "service_role";



GRANT ALL ON TABLE "public"."news_feed_posts" TO "anon";
GRANT ALL ON TABLE "public"."news_feed_posts" TO "authenticated";
GRANT ALL ON TABLE "public"."news_feed_posts" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."therapist_profiles" TO "anon";
GRANT ALL ON TABLE "public"."therapist_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."therapist_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."therapist_verification_requests" TO "anon";
GRANT ALL ON TABLE "public"."therapist_verification_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."therapist_verification_requests" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "service_role";






























RESET ALL;
