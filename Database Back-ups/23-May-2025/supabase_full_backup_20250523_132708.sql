

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
SET session_replication_role = replica;

--
-- PostgreSQL database dump
--

-- Dumped from database version 15.8
-- Dumped by pg_dump version 15.8

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
-- Data for Name: audit_log_entries; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

INSERT INTO "auth"."audit_log_entries" ("instance_id", "id", "payload", "created_at", "ip_address") VALUES
	('00000000-0000-0000-0000-000000000000', '42fc455e-814e-4e45-a569-12f3d46686e3', '{"action":"user_confirmation_requested","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-04-26 14:27:31.181542+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c4d111c1-90e2-493b-a8d7-f5bb39af428a', '{"action":"user_signedup","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-04-26 14:37:04.958675+00', ''),
	('00000000-0000-0000-0000-000000000000', '5c5f1814-f87e-46ba-9b6e-c6fdd4677250', '{"action":"user_recovery_requested","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"user"}', '2025-04-27 05:14:15.372524+00', ''),
	('00000000-0000-0000-0000-000000000000', '31499780-b3a0-4c71-91a7-8bb9c586038f', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-04-27 05:14:26.828496+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c2bcc479-f590-4f4f-a063-7d6f365a1853', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-27 05:21:05.946305+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e37e76ee-6d29-4d08-81a3-7268e97cfd03', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-27 05:21:21.639009+00', ''),
	('00000000-0000-0000-0000-000000000000', '87c19ed7-ccaf-4230-b1da-4605fe61aa89', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-04-27 05:29:45.73902+00', ''),
	('00000000-0000-0000-0000-000000000000', '6874d0e7-000c-46cc-bb5e-b49c7d9d5e06', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-27 05:29:56.419028+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fbc68eab-04f2-4c02-aaf4-40d9e23416e3', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-04-27 05:30:02.847925+00', ''),
	('00000000-0000-0000-0000-000000000000', '2790d61d-154a-462a-90d5-b2531afea8b9', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-27 05:30:31.427586+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b49988d0-9b61-4495-b3b8-a0ccff19551f', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-04-27 05:30:34.994596+00', ''),
	('00000000-0000-0000-0000-000000000000', '07810cbc-11ac-43fb-881c-6b6f7d870a21', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-27 05:35:04.30378+00', ''),
	('00000000-0000-0000-0000-000000000000', '6f4d8fc5-a24e-4416-ae70-d79201f705e2', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-27 06:17:16.721001+00', ''),
	('00000000-0000-0000-0000-000000000000', '0f4ce38b-45af-48a1-97a0-9352ec94e382', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-04-27 06:17:20.437127+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a52b9313-7d9d-4138-8816-0ec914adbd4e', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-28 06:10:43.969609+00', ''),
	('00000000-0000-0000-0000-000000000000', '35a144c9-c354-4867-a59a-a09807042306', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-28 08:10:44.827149+00', ''),
	('00000000-0000-0000-0000-000000000000', '4bf056cd-3df5-4b1f-bd24-8eb71f87697a', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-28 08:10:44.833328+00', ''),
	('00000000-0000-0000-0000-000000000000', '2b7976f4-a7cf-405d-93aa-bbd19114897c', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-28 08:18:41.760626+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dbd82d96-ea49-431e-84f1-1a8707f2e567', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-28 09:33:31.386513+00', ''),
	('00000000-0000-0000-0000-000000000000', '0f00c67e-6294-4077-83ce-2a74a9eac655', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-28 09:33:31.388078+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f96255b0-4b7c-489a-aa69-e692fbf3dc07', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-28 09:33:34.399292+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd1b7f744-b0fe-4d02-990c-f650787ab8dc', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-28 09:33:34.399948+00', ''),
	('00000000-0000-0000-0000-000000000000', '5b081f28-4ee5-46f5-b34c-7483f0e046d9', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-28 09:37:49.540014+00', ''),
	('00000000-0000-0000-0000-000000000000', '3bda2385-71aa-48dd-8912-2dc5715bfd0d', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-04-28 09:43:39.004412+00', ''),
	('00000000-0000-0000-0000-000000000000', 'efb528ef-dd7f-45bf-b031-b9f3436641d4', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-28 09:43:49.413189+00', ''),
	('00000000-0000-0000-0000-000000000000', '95af4072-f3b9-45fb-ae16-81fd64d90436', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-04-28 09:45:30.285595+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a72d5f4d-c682-4422-9261-98fa6a48a817', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-28 15:02:56.672358+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e41520e5-fde3-4055-bd8c-fec1f208a3b5', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-29 10:33:39.583699+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b5add288-368a-48c1-b9b0-f3e5eb84d455', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-29 10:33:39.594409+00', ''),
	('00000000-0000-0000-0000-000000000000', '4e88332c-9563-4cdf-bb0c-30c5aa441f2f', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-29 15:05:20.405441+00', ''),
	('00000000-0000-0000-0000-000000000000', '6126936a-589a-4630-9381-32df234f1634', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-29 15:22:05.728912+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e54b1b02-dae0-49d8-8450-a1eb259c3cab', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-29 15:23:22.430471+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fd4bd3d4-5444-4337-935a-580c7fce8e66', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-29 15:25:29.025369+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dc8f46a2-0a86-492a-93f7-3fe0994b7f03', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-29 16:06:46.983384+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dc3d0d14-7379-4a30-9001-12aef50ba1b7', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-29 16:06:46.985506+00', ''),
	('00000000-0000-0000-0000-000000000000', '8ea6b767-8ee3-439f-b17c-5144ca529b95', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-29 16:24:02.086635+00', ''),
	('00000000-0000-0000-0000-000000000000', '4a4d9f28-21a4-4bce-ba9f-4c94bb3f8dbe', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-29 16:24:02.087615+00', ''),
	('00000000-0000-0000-0000-000000000000', '48c2745f-1689-43bd-be29-440913afe56e', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-29 16:49:11.953609+00', ''),
	('00000000-0000-0000-0000-000000000000', '9176834f-eb29-4892-89d9-33a959ab0a54', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-29 16:49:11.954576+00', ''),
	('00000000-0000-0000-0000-000000000000', '169d4980-4c7e-4461-a46a-18a5a5c8346d', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-29 17:05:32.53338+00', ''),
	('00000000-0000-0000-0000-000000000000', '47564a3b-a125-4a47-96fb-a5c30c0df38a', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-04-29 17:05:32.535009+00', ''),
	('00000000-0000-0000-0000-000000000000', '256e71f3-a2b1-48fd-bbfc-3e6baca1bd07', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-29 17:08:55.867029+00', ''),
	('00000000-0000-0000-0000-000000000000', '745b1c96-b7d6-44b2-80f5-fda36620d0c6', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-04-29 17:09:03.330115+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd1d19591-188e-4894-88bc-07db1709ea96', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-29 17:10:23.14067+00', ''),
	('00000000-0000-0000-0000-000000000000', '8a019dc1-5688-49ed-81fe-3fe200b0ca60', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-04-29 17:15:17.741707+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cccb0a7f-22e2-4c74-af57-ab93b7401ee4', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-04-30 13:59:58.899169+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a5b8e668-45bc-43e3-891c-f40ab125042d', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-04-30 14:00:41.908759+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ff6fdb15-7dc2-45de-984a-289161bef28f', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-01 02:45:59.708357+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f6adc530-6f09-4871-927b-1476d94833ac', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-01 02:47:09.426207+00', ''),
	('00000000-0000-0000-0000-000000000000', '8d829a26-cdd7-4c4f-8554-71e5450a136f', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-01 02:48:12.041113+00', ''),
	('00000000-0000-0000-0000-000000000000', 'eb85ebe4-a97d-4b1c-97e8-1cde99057a7e', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-01 02:52:43.434611+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dd008a6d-23e3-4312-a804-55c41805ba0d', '{"action":"user_confirmation_requested","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-01 06:09:23.575276+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ba2f8666-7727-4ccf-bbef-8da7881d86a2', '{"action":"user_confirmation_requested","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-01 06:12:53.237426+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c631463d-3c52-4616-bc1b-0f2c54530096', '{"action":"user_confirmation_requested","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-01 06:19:47.833977+00', ''),
	('00000000-0000-0000-0000-000000000000', '9bf8de25-f232-4820-b4bc-602baff7f6c7', '{"action":"user_confirmation_requested","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-01 06:20:49.942126+00', ''),
	('00000000-0000-0000-0000-000000000000', '794e7422-3550-4978-b4be-81fbeb90957e', '{"action":"user_confirmation_requested","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-01 06:22:03.244761+00', ''),
	('00000000-0000-0000-0000-000000000000', '1e6d1be6-fa4b-48cd-bd91-0fcf1d7068cd', '{"action":"user_signedup","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-01 06:22:17.552453+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd976b06a-3dd6-415c-9c7a-f6d657ffaf66', '{"action":"logout","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-01 06:22:55.019045+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f75d77d0-70ff-4106-ac22-b7b8f5bea913', '{"action":"user_confirmation_requested","actor_id":"fd90e8e9-b897-4d3c-becb-48291c6bf361","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-01 06:23:13.846005+00', ''),
	('00000000-0000-0000-0000-000000000000', '715ff3af-2fea-4270-b45c-033ba7a58e7f', '{"action":"login","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-01 06:28:22.482807+00', ''),
	('00000000-0000-0000-0000-000000000000', '2f4b0728-7083-48ba-b07c-53f1e0de3b68', '{"action":"logout","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-01 06:34:30.058842+00', ''),
	('00000000-0000-0000-0000-000000000000', '866ac37c-b4f4-4f4f-99d6-5227a6268da0', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-01 06:34:37.483964+00', ''),
	('00000000-0000-0000-0000-000000000000', '74074080-4ca6-409d-8270-e667d5349d85', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-01 06:44:46.924791+00', ''),
	('00000000-0000-0000-0000-000000000000', 'aa58647f-a79a-4252-b99e-645ce8967de4', '{"action":"user_signedup","actor_id":"fd90e8e9-b897-4d3c-becb-48291c6bf361","actor_name":"Gorjan Ghita","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-01 07:01:40.599329+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e3077070-b488-4751-947c-28d1539c951a', '{"action":"user_signedup","actor_id":"c1875f81-a33c-4f5d-9278-2969d1ef4ef5","actor_name":"Baciu Raul","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-01 07:02:09.672078+00', ''),
	('00000000-0000-0000-0000-000000000000', '7f6ee8a0-f289-4357-9f3a-7e8f4521998d', '{"action":"login","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-01 07:35:36.585427+00', ''),
	('00000000-0000-0000-0000-000000000000', '474a40b4-92a1-422e-9905-87bfe68aa151', '{"action":"login","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-01 07:37:01.816859+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd9178a73-860e-47b2-bf5a-8be3d5849b34', '{"action":"login","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-01 08:04:09.213029+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c001c38f-3d94-4143-bc1b-664a8c6e407b', '{"action":"login","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-01 08:05:29.199665+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c66c23fe-430d-4a2d-a592-23d36a8fd865', '{"action":"login","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-01 08:07:05.390744+00', ''),
	('00000000-0000-0000-0000-000000000000', '119c2a61-c9c8-42a4-9210-3a7f98f27a82', '{"action":"login","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-01 08:10:26.904896+00', ''),
	('00000000-0000-0000-0000-000000000000', '0dccf969-eda2-48c5-aabb-5ae04505d865', '{"action":"logout","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-01 08:13:19.60673+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e7e3ffe9-9601-42ee-a325-61a3f2e9008b', '{"action":"login","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-01 08:13:23.896199+00', ''),
	('00000000-0000-0000-0000-000000000000', '5d1da282-d201-49ad-81f1-9783b3791a0e', '{"action":"login","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-01 08:21:33.465231+00', ''),
	('00000000-0000-0000-0000-000000000000', '21966cb9-a70c-4683-833c-39760fa1cc3d', '{"action":"login","actor_id":"fd90e8e9-b897-4d3c-becb-48291c6bf361","actor_name":"Gorjan Ghita","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-01 08:33:49.404773+00', ''),
	('00000000-0000-0000-0000-000000000000', '28fbacbb-f750-44a5-a1ad-b0971cfa7358', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-01 08:34:21.410443+00', ''),
	('00000000-0000-0000-0000-000000000000', '498b9ba5-7683-4c95-ae37-1ebc46400d71', '{"action":"logout","actor_id":"fd90e8e9-b897-4d3c-becb-48291c6bf361","actor_name":"Gorjan Ghita","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-01 08:39:47.942912+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b80a0ad3-5057-4484-9629-813dc33e5c64', '{"action":"login","actor_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-01 08:39:53.798077+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ac6c3567-b0f6-401d-b556-f77744580393', '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role","actor_via_sso":false,"log_type":"team","traits":{"user_email":"gorjy.ghy@gmail.com","user_id":"fd90e8e9-b897-4d3c-becb-48291c6bf361","user_phone":""}}', '2025-05-01 08:48:28.133712+00', ''),
	('00000000-0000-0000-0000-000000000000', '975129d4-a3a8-447c-abd0-23295ac1bbfe', '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role","actor_via_sso":false,"log_type":"team","traits":{"user_email":"lao.water7@gmail.com","user_id":"f56135b6-cfd7-4c73-8bb0-e3b47a705dfc","user_phone":""}}', '2025-05-01 08:48:29.825376+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e38e689a-13c4-421b-97a6-9f0fd8bf6faf', '{"action":"user_signedup","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-01 15:06:56.1971+00', ''),
	('00000000-0000-0000-0000-000000000000', '469eba29-857f-4627-a6bd-a43f3b35b00a', '{"action":"logout","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-01 15:17:55.889761+00', ''),
	('00000000-0000-0000-0000-000000000000', 'eaebd49f-052a-4d45-a661-a93f5989e416', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-01 15:18:13.040864+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e19e8d6b-f881-4423-bbc9-66f539c8b207', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-01 15:21:34.031782+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b9f774a7-4361-4cae-b328-4b3079614f2d', '{"action":"user_signedup","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-01 16:11:48.64447+00', ''),
	('00000000-0000-0000-0000-000000000000', '894c2e5c-d7b5-4503-ad78-7ea452cf090f', '{"action":"user_signedup","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-01 16:13:19.547334+00', ''),
	('00000000-0000-0000-0000-000000000000', '8692e9c3-dcba-44ab-a818-0e8cd9246a3d', '{"action":"logout","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-01 16:13:33.951987+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f0d06dac-f093-479d-8b78-ad9c37c1e03f', '{"action":"login","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-01 16:13:43.593645+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fb3f492f-f355-4496-a792-eef92bb4bc56', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-01 16:23:32.186374+00', ''),
	('00000000-0000-0000-0000-000000000000', 'bfb9b6f6-3d67-49c6-9a31-f540bf13abce', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-01 17:03:08.858195+00', ''),
	('00000000-0000-0000-0000-000000000000', '2bbf4476-1e24-46eb-af00-8ac8852bcc4d', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-02 01:37:49.177197+00', ''),
	('00000000-0000-0000-0000-000000000000', '52d8ad8c-87ef-4d63-9714-e41195e35492', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-02 01:37:49.184781+00', ''),
	('00000000-0000-0000-0000-000000000000', '1598aab7-d0b5-40f7-a94a-ab1cd965780e', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-02 03:27:54.444212+00', ''),
	('00000000-0000-0000-0000-000000000000', '732d1d89-5fa5-4e32-8143-ac435597bcb9', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-02 03:27:54.445049+00', ''),
	('00000000-0000-0000-0000-000000000000', '88df7d05-894e-425d-8a34-4f50bf9dc6de', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-02 03:28:06.950077+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ad3b646b-bc10-419b-854b-c680a7a66e83', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-02 07:00:36.974795+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd838c88d-0151-404e-8697-7f322d636cfd', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-02 07:00:36.986879+00', ''),
	('00000000-0000-0000-0000-000000000000', 'aecf23b3-a9e4-4b65-a2a0-e92f65dbadd5', '{"action":"logout","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-02 07:22:59.21913+00', ''),
	('00000000-0000-0000-0000-000000000000', '551de503-1dd2-4556-a522-0b880eb5d7da', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-03 06:06:37.828887+00', ''),
	('00000000-0000-0000-0000-000000000000', 'bcdd4d57-a1d4-49e0-ad77-8fbf8dd45d64', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-03 10:12:50.801032+00', ''),
	('00000000-0000-0000-0000-000000000000', '2ec1f941-d1ed-4578-baf2-b67cfd9a172c', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-03 10:14:22.188451+00', ''),
	('00000000-0000-0000-0000-000000000000', '74bb1e2b-d5fd-44a7-a296-0360629cd083', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-03 10:15:00.540037+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b5bb9b41-258c-4f5e-81ad-255c62720449', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-03 10:47:45.544072+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd59c5eea-e441-44b2-b584-af8586c36542', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-03 10:47:45.546042+00', ''),
	('00000000-0000-0000-0000-000000000000', '634d3cc4-60fa-43f4-953f-7d275b28f189', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-03 11:26:44.083772+00', ''),
	('00000000-0000-0000-0000-000000000000', '0f3bd866-5e87-435c-9f23-4675a386d668', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-03 11:26:44.086594+00', ''),
	('00000000-0000-0000-0000-000000000000', '93b1fb0f-18a8-45dd-974d-9b613651333f', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-03 22:32:51.05794+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e0cad3f7-f5e3-41aa-81c4-4a0448a71669', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-03 22:32:51.07648+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd4f0b810-b049-45f5-9626-5fc8a9aa7343', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 03:07:13.439485+00', ''),
	('00000000-0000-0000-0000-000000000000', '04719390-5c83-4b4b-b0c3-f0bfc64a02be', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 03:07:13.454588+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fe56f075-958f-4c56-88b7-b3577466625c', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 04:49:47.19631+00', ''),
	('00000000-0000-0000-0000-000000000000', '2894baa5-25f9-4bc5-a3be-9016402dc62b', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 04:49:47.197233+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c5944ebb-b2e8-42b9-bb53-521ba9d81ea3', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 04:51:56.286907+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f30b256d-ca08-4280-8f3c-42b68412c968', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 04:51:56.287832+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ce4968b6-442f-4450-ac0b-a144b7e3c0b6', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 05:30:29.47942+00', ''),
	('00000000-0000-0000-0000-000000000000', '40c76e71-8d2c-4ad4-be4f-bffaa436d04f', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 05:30:29.483428+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e4c67427-f900-4335-8bd1-ff3f8e54d925', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-04 06:07:31.696037+00', ''),
	('00000000-0000-0000-0000-000000000000', 'df166cff-2b92-4b5a-ac23-2846aa4b88ab', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-04 06:10:30.482504+00', ''),
	('00000000-0000-0000-0000-000000000000', '7655507b-10f9-4324-b083-b0fff2bb142b', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 09:37:52.696085+00', ''),
	('00000000-0000-0000-0000-000000000000', '489124c9-afc4-4887-b74e-43924f1d925a', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 09:37:52.712051+00', ''),
	('00000000-0000-0000-0000-000000000000', '8d1f3ffd-d477-4398-b08c-fc2bc0993e4b', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 10:06:04.909023+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd99e8a72-e9b0-476a-b8fc-7acf97114019', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 10:06:04.911+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b4a6b9d0-e715-4cc4-bd87-ea3656aeb55a', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 10:06:16.067364+00', ''),
	('00000000-0000-0000-0000-000000000000', '5ae1ab53-300c-4b36-b092-587958809a7b', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 10:06:16.068071+00', ''),
	('00000000-0000-0000-0000-000000000000', '07f75f75-1beb-42cd-b3fd-97116ec39ca4', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-04 10:08:57.682071+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cb80a6b7-e86c-4aa2-b1ef-ffd021c5465f', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-04 10:11:00.323498+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f7c73cf6-b1af-48c9-9046-236f96cf4d03', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 10:27:46.188304+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b9d3699d-eaca-4b96-b787-a0a0a962f382', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-04 10:27:46.189716+00', ''),
	('00000000-0000-0000-0000-000000000000', '7bcf540b-01b9-4752-a154-69177bdbddba', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-04 10:29:57.57777+00', ''),
	('00000000-0000-0000-0000-000000000000', 'df89d12f-8abb-48a1-b12e-6d58cdb4ee87', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-04 10:30:06.518389+00', ''),
	('00000000-0000-0000-0000-000000000000', '612d725e-53fd-463f-bdbc-993aabbcd561', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-04 10:36:08.808711+00', ''),
	('00000000-0000-0000-0000-000000000000', '11af9be6-8662-4061-9640-b960033810a7', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-04 10:36:11.998924+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c3472b24-b6fb-4b4b-be89-48f123081545', '{"action":"login","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-04 10:36:20.659789+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c2fcf759-e7bf-4199-b862-1538021cff2c', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-04 15:25:59.521147+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fa404a91-c1f7-4604-b13c-a99a31ce42ee', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-04 15:26:01.937448+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e2708669-9254-461c-be0d-dd182e6c92f6', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-04 15:26:07.181917+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b2f77d29-7119-4a16-83ae-b48929622404', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-05 06:34:12.688347+00', ''),
	('00000000-0000-0000-0000-000000000000', '38179a9c-4ffc-4736-af3f-85e1ce1497b3', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-05 06:34:12.697099+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f3e79c27-6ef4-4f8a-8e26-ee3ff11f0633', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-05 06:47:10.711854+00', ''),
	('00000000-0000-0000-0000-000000000000', '7e48c43f-3ccf-4412-9884-5e6ee94bf194', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-05 06:50:15.808776+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e781c649-9b7b-4005-8dce-9df5aad72bce', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-05 07:49:12.739032+00', ''),
	('00000000-0000-0000-0000-000000000000', '586713eb-d648-493c-8604-a0cc82549f30', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-05 07:49:12.7407+00', ''),
	('00000000-0000-0000-0000-000000000000', '70acffb6-eaa2-441e-a8e5-81317621f772', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-05 08:06:23.80036+00', ''),
	('00000000-0000-0000-0000-000000000000', '461f0e41-3378-4f48-8559-4c87db4195da', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-05 11:52:58.043955+00', ''),
	('00000000-0000-0000-0000-000000000000', '7857149a-c268-448c-b661-72e182837915', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-05 13:32:09.228634+00', ''),
	('00000000-0000-0000-0000-000000000000', '14fcfd7b-6018-4779-aacc-04566eaffe70', '{"action":"login","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-05 14:23:44.55828+00', ''),
	('00000000-0000-0000-0000-000000000000', '508b199b-4982-4d49-9339-670e6b39620f', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-05 14:26:43.479727+00', ''),
	('00000000-0000-0000-0000-000000000000', '1b4d3c49-6f93-4fbb-9c5b-20edf7be0d1b', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-05 14:26:43.480605+00', ''),
	('00000000-0000-0000-0000-000000000000', '2a8c22f5-5d1a-46ee-ac47-4a615eb82ddf', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-05 14:28:59.638949+00', ''),
	('00000000-0000-0000-0000-000000000000', '5d2aedf7-90fa-4f7f-9725-4f8c1ce3f19a', '{"action":"login","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-05 14:29:05.642145+00', ''),
	('00000000-0000-0000-0000-000000000000', '8fa4c67e-53c0-4da6-a142-9de778bd4975', '{"action":"login","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-05 14:48:58.684106+00', ''),
	('00000000-0000-0000-0000-000000000000', '9770fe5c-4561-40b8-a6e0-c88fa016f187', '{"action":"logout","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-05 14:49:39.519871+00', ''),
	('00000000-0000-0000-0000-000000000000', '3b311086-517d-4f64-a57c-319bb6b4a825', '{"action":"login","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-05 14:49:45.519175+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd2fd6b4a-db26-4899-97f8-885892a4033d', '{"action":"token_refreshed","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-05 15:42:39.040894+00', ''),
	('00000000-0000-0000-0000-000000000000', '01c1e643-1061-409e-ad4d-bafd4300fa6f', '{"action":"token_revoked","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-05 15:42:39.044019+00', ''),
	('00000000-0000-0000-0000-000000000000', '70f2f922-a63f-45ba-934b-a69c595a08c0', '{"action":"token_refreshed","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-06 07:03:48.691245+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ebfd1c5b-7fca-488c-b091-3ed449e2198e', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-06 07:15:22.197886+00', ''),
	('00000000-0000-0000-0000-000000000000', '8f3da9a0-865b-4935-87f6-3c3f18256c45', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-06 07:15:36.481891+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ceb3d03e-dd5e-4895-b319-ae90db38dad5', '{"action":"logout","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-06 07:16:22.4536+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd3c15a21-04b2-4903-87cb-535635cf88a3', '{"action":"user_signedup","actor_id":"2d15cf78-b2a0-4014-8c9e-95738b853eb9","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-06 07:16:44.600612+00', ''),
	('00000000-0000-0000-0000-000000000000', '921a596f-8cd2-47ef-80fc-d25ebbc0f604', '{"action":"logout","actor_id":"2d15cf78-b2a0-4014-8c9e-95738b853eb9","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-06 07:19:34.163763+00', ''),
	('00000000-0000-0000-0000-000000000000', '67ecbf6b-801e-4892-a5cb-32e96e5e56ad', '{"action":"login","actor_id":"2d15cf78-b2a0-4014-8c9e-95738b853eb9","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-06 07:19:42.916224+00', ''),
	('00000000-0000-0000-0000-000000000000', '4b70daa4-f2a3-42d2-821a-dac852fcb99b', '{"action":"user_signedup","actor_id":"1bddeabd-0b2b-4a1e-8f0c-9544ad6bc003","actor_name":"Gorjan Ghita","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-06 07:19:46.433493+00', ''),
	('00000000-0000-0000-0000-000000000000', '5e8d384a-c4f6-4f19-bf82-b4646a79bb14', '{"action":"login","actor_id":"1bddeabd-0b2b-4a1e-8f0c-9544ad6bc003","actor_name":"Gorjan Ghita","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-06 07:22:24.730319+00', ''),
	('00000000-0000-0000-0000-000000000000', '306f670b-e761-49c4-acc1-fec6c768ead0', '{"action":"logout","actor_id":"1bddeabd-0b2b-4a1e-8f0c-9544ad6bc003","actor_name":"Gorjan Ghita","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-06 07:25:34.415914+00', ''),
	('00000000-0000-0000-0000-000000000000', '00299845-f36f-4930-870d-deb27d40f399', '{"action":"login","actor_id":"1bddeabd-0b2b-4a1e-8f0c-9544ad6bc003","actor_name":"Gorjan Ghita","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-06 07:25:46.414602+00', ''),
	('00000000-0000-0000-0000-000000000000', '0cbf9b97-4e59-40ea-a02a-5d9c15217842', '{"action":"logout","actor_id":"1bddeabd-0b2b-4a1e-8f0c-9544ad6bc003","actor_name":"Gorjan Ghita","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-06 07:26:15.915555+00', ''),
	('00000000-0000-0000-0000-000000000000', '160612c2-f35c-4e78-b604-2486b89d14be', '{"action":"logout","actor_id":"2d15cf78-b2a0-4014-8c9e-95738b853eb9","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-06 07:30:45.668174+00', ''),
	('00000000-0000-0000-0000-000000000000', '22e20126-91a4-40b6-958d-276dd7e87b98', '{"action":"login","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-06 07:35:06.817599+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f9b34c69-d7e7-4746-825d-78696c2b820b', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-06 07:35:09.853687+00', ''),
	('00000000-0000-0000-0000-000000000000', '9c46c4d3-82c1-415a-a014-e7292b28aa58', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-06 08:35:01.035431+00', ''),
	('00000000-0000-0000-0000-000000000000', '289100e1-c63e-4038-afa2-29d2fe318e34', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-06 08:35:01.039783+00', ''),
	('00000000-0000-0000-0000-000000000000', '397a7122-2533-4db9-8fe0-2fbf9adfcce8', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-06 09:40:07.962944+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c0db63c4-356d-4cd3-b466-154ef304a46c', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-06 09:40:07.966088+00', ''),
	('00000000-0000-0000-0000-000000000000', '7d030880-4a44-45eb-90a0-9bc7ed93e394', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-06 10:01:13.541073+00', ''),
	('00000000-0000-0000-0000-000000000000', '89406318-8354-419d-8043-b7ac1dd813e2', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-06 10:01:13.543883+00', ''),
	('00000000-0000-0000-0000-000000000000', '8f756f74-e4d0-4a07-9f51-3e7f5f08f819', '{"action":"logout","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-06 10:06:24.58604+00', ''),
	('00000000-0000-0000-0000-000000000000', '0d4e19ad-2e06-411c-9b0a-79b71d542694', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-07 00:39:40.893888+00', ''),
	('00000000-0000-0000-0000-000000000000', '7bec0290-5d7b-4e85-a184-b01847d419ff', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-07 00:40:36.035266+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b5988baa-f38c-4a8a-a90a-8ad16285a5a7', '{"action":"user_confirmation_requested","actor_id":"ae0309b5-4017-4d32-9b5b-74d2f0323837","actor_username":"sory.loby2@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-07 00:41:00.236515+00', ''),
	('00000000-0000-0000-0000-000000000000', '650310a3-4edc-430b-b1ea-eb23ebeb0a46', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-07 03:13:36.338577+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ced6df29-6ecc-4dca-88df-579761f48621', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-07 03:16:39.892641+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b29d2f32-9878-4eff-9871-4ed5f64a51ac', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-07 05:11:12.322634+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f7833143-21da-4b08-aa59-ce4c057f9b90', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-07 05:11:12.325345+00', ''),
	('00000000-0000-0000-0000-000000000000', '1dc13c47-ce65-41ce-a5db-9cca565aaf05', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-07 07:23:40.755526+00', ''),
	('00000000-0000-0000-0000-000000000000', '68e90861-47ed-4e2c-a9fa-0bec8d1d2f1f', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-07 07:23:40.763441+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e5d48585-22e1-402a-8f54-50955ef16f21', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-07 07:24:01.157753+00', ''),
	('00000000-0000-0000-0000-000000000000', '9b497d36-51e4-4da9-94df-38395759e3ce', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-07 07:24:09.051584+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b5ce7c6d-1b63-4942-99b8-e4f879feb3e6', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-07 07:25:45.391768+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f508e37e-e567-4622-8e83-81b267f74f0e', '{"action":"login","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-07 07:25:52.568718+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a70999cc-a2b0-462e-a60b-213ad46c8864', '{"action":"logout","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-07 07:26:02.594388+00', ''),
	('00000000-0000-0000-0000-000000000000', '9df47d85-7cca-4718-a3c1-f44e067f173b', '{"action":"user_recovery_requested","actor_id":"1bddeabd-0b2b-4a1e-8f0c-9544ad6bc003","actor_name":"Gorjan Ghita","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"user"}', '2025-05-07 07:27:56.67574+00', ''),
	('00000000-0000-0000-0000-000000000000', '205cfd8d-6e3f-44ff-a643-d3f48bb7f731', '{"action":"login","actor_id":"1bddeabd-0b2b-4a1e-8f0c-9544ad6bc003","actor_name":"Gorjan Ghita","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-07 07:28:15.379528+00', ''),
	('00000000-0000-0000-0000-000000000000', 'bc78da00-5fe3-4561-b791-92c069acc5da', '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role","actor_via_sso":false,"log_type":"team","traits":{"user_email":"gorjy.ghy@gmail.com","user_id":"1bddeabd-0b2b-4a1e-8f0c-9544ad6bc003","user_phone":""}}', '2025-05-07 07:29:29.026157+00', ''),
	('00000000-0000-0000-0000-000000000000', '0e86adc0-340e-49dc-8d1d-a1a0ecb1c08f', '{"action":"user_confirmation_requested","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-07 07:29:44.82753+00', ''),
	('00000000-0000-0000-0000-000000000000', '1e420198-25e8-48e3-a5be-862e9f359809', '{"action":"user_signedup","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-07 07:29:56.379576+00', ''),
	('00000000-0000-0000-0000-000000000000', '1e7eac88-6dd7-4e09-a897-6d8ea03c3357', '{"action":"login","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-07 07:30:03.214693+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fc4a3c39-490a-4dd8-9dfd-01d253a14aab', '{"action":"logout","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-07 07:30:32.148579+00', ''),
	('00000000-0000-0000-0000-000000000000', '5b05bcbd-6084-42c4-87b1-4c5985808bbc', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-07 07:30:37.081074+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f9d3c182-b76e-4caa-9228-d78faabde9ff', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-07 12:24:05.229867+00', ''),
	('00000000-0000-0000-0000-000000000000', '65e08af7-6ac8-4191-a4e9-80c68cfe9480', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-07 12:24:05.24234+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd14dc0d2-a082-4106-94d0-8eb8509a8dd5', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-07 15:04:20.943914+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b058f906-c8e1-4a3f-85c3-487037b40515', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-07 15:04:20.957153+00', ''),
	('00000000-0000-0000-0000-000000000000', '91a77547-96f8-4796-b343-625b4e1f58e0', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-07 15:58:18.794925+00', ''),
	('00000000-0000-0000-0000-000000000000', '8f5019e4-6ab0-42cf-9760-d9ef136212ad', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-07 15:58:18.796396+00', ''),
	('00000000-0000-0000-0000-000000000000', '2c4a6972-ac24-46c2-8df8-6d6ddc63d918', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-08 14:41:54.865655+00', ''),
	('00000000-0000-0000-0000-000000000000', '4d250fdb-badf-4fb2-8e43-58de01d8ed36', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-08 14:41:54.888787+00', ''),
	('00000000-0000-0000-0000-000000000000', '45535675-d6fc-43d8-b214-620005b28c70', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-09 04:48:39.810413+00', ''),
	('00000000-0000-0000-0000-000000000000', 'bbebee41-38eb-43a9-a730-6a99b81cea6e', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-09 06:50:29.299102+00', ''),
	('00000000-0000-0000-0000-000000000000', '19b5bb5b-f41e-42f8-ad5f-11ff50d2a53f', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-09 06:50:29.318188+00', ''),
	('00000000-0000-0000-0000-000000000000', 'bed74704-5a65-49ff-9410-010963be4720', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-09 09:06:02.074924+00', ''),
	('00000000-0000-0000-0000-000000000000', '651d7740-f369-41d6-b379-a5c8153781e9', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-09 09:06:02.079338+00', ''),
	('00000000-0000-0000-0000-000000000000', '689e1e0f-05b6-4571-8ec2-e78a893a9e3b', '{"action":"login","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-09 16:35:43.862032+00', ''),
	('00000000-0000-0000-0000-000000000000', '08b42b76-8091-4279-b5ac-c2415ebc403b', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-09 18:36:40.500395+00', ''),
	('00000000-0000-0000-0000-000000000000', '373dd47b-c567-4f9c-bdb9-d3a20b1f3981', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-09 18:36:40.505034+00', ''),
	('00000000-0000-0000-0000-000000000000', '732ecc0e-ea48-4480-87a9-470c347ea624', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-10 02:20:20.362484+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ac97a117-d57e-4149-b097-f63bbfb5e685', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 02:50:35.034954+00', ''),
	('00000000-0000-0000-0000-000000000000', 'be7e7315-614d-4e22-9434-68f079095ace', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 02:50:35.036909+00', ''),
	('00000000-0000-0000-0000-000000000000', '3917ce83-d672-4aba-8d57-b336159055be', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 04:02:42.142178+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e46cc8be-4cc2-487d-b3fd-451a827b7778', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 04:02:42.144189+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd7518c3e-67c1-40a4-a101-336edb3df647', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 05:14:45.037362+00', ''),
	('00000000-0000-0000-0000-000000000000', '2b40dda4-9f5b-41da-9249-cd984a53ab67', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 05:14:45.038711+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f6c77cf2-27fc-4b27-b6a5-317bee87a431', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 06:14:56.283898+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f45f4c24-e19d-4ede-8fa1-15cf7e192b0a', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 06:14:56.286885+00', ''),
	('00000000-0000-0000-0000-000000000000', '693375b9-093b-47ba-a0d2-04f4f7583f58', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 07:29:26.69224+00', ''),
	('00000000-0000-0000-0000-000000000000', '1c8020c4-a5c9-441f-ba97-ba1c5c813f88', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 07:29:26.702901+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f7dd5230-552b-45db-a893-c870495cbc9a', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-10 08:09:02.21429+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f6f4541e-ba7b-4f17-8bec-2b944f379525', '{"action":"login","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-10 08:09:09.14582+00', ''),
	('00000000-0000-0000-0000-000000000000', '23d18153-a2e5-4d58-bf54-cd37933d45a4', '{"action":"logout","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-10 08:43:01.702299+00', ''),
	('00000000-0000-0000-0000-000000000000', '0002e42e-407c-4b87-9237-e57e30c03213', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-10 08:43:05.901937+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd4e909d2-cd67-41e5-8c27-5d2b97e8c847', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 08:46:23.570395+00', ''),
	('00000000-0000-0000-0000-000000000000', '1ec60d1c-7563-428a-b808-eb6bd81a365f', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 08:46:23.572472+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f6771070-9b90-432c-b4f0-2fb7e96077a7', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 10:11:06.560009+00', ''),
	('00000000-0000-0000-0000-000000000000', '3c2a62a8-1f6e-4932-8580-1b264c996cf6', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 10:11:06.563824+00', ''),
	('00000000-0000-0000-0000-000000000000', '560d40af-bf0f-4d25-a8a5-c93e541b4560', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 10:11:06.831841+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd7ad715b-c1e9-401f-ae3d-2734021bfc91', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 10:16:00.044264+00', ''),
	('00000000-0000-0000-0000-000000000000', '70e2e414-915d-4ab5-916d-6497328c66a7', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 10:16:00.053913+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ec6552c8-8de4-40ba-b8f7-7040257b77cf', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-10 13:27:13.697242+00', ''),
	('00000000-0000-0000-0000-000000000000', '321daccf-5710-46c7-9583-9b64d111e58f', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 15:46:15.428064+00', ''),
	('00000000-0000-0000-0000-000000000000', '4ef71a01-f6e4-4a1a-a9fe-bd7e095d4d00', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 15:46:15.431689+00', ''),
	('00000000-0000-0000-0000-000000000000', '41da3d04-d125-4d7f-b591-cd27eae1b211', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 15:46:29.644546+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cfa7e27e-041a-47a5-8aaf-294a1408b8c1', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-10 15:46:29.645143+00', ''),
	('00000000-0000-0000-0000-000000000000', '2ee48ce1-c774-4e9f-a2fb-2720fb8a8542', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-10 16:28:50.84375+00', ''),
	('00000000-0000-0000-0000-000000000000', '9cdc1656-8ee5-42c5-bab6-155b0e11419e', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-10 16:28:54.751142+00', ''),
	('00000000-0000-0000-0000-000000000000', '5f485166-8953-4194-9219-55e7921e6f0f', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-10 16:38:17.121807+00', ''),
	('00000000-0000-0000-0000-000000000000', 'be6ac6ae-2d1f-4189-8bf0-89f9c1fcb619', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-10 16:41:07.447633+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a5ca0ff8-003c-439b-be0b-7aae7ad7fc4f', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-10 16:42:53.332485+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cd1031cd-176a-4e05-8a11-658dc668989a', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-10 16:50:55.981021+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e2b7fb02-a60a-4717-8651-9be839754252', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-10 16:51:35.51257+00', ''),
	('00000000-0000-0000-0000-000000000000', 'bb5d290f-220f-48d1-b613-5a0798cff981', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-10 17:22:54.438479+00', ''),
	('00000000-0000-0000-0000-000000000000', '5966dfb8-3316-4ea7-b6e5-f0a3e12c6e27', '{"action":"login","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-10 17:22:59.640767+00', ''),
	('00000000-0000-0000-0000-000000000000', '8310b166-0655-4c8d-8d20-2ed8f211a24c', '{"action":"token_refreshed","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 06:08:53.335453+00', ''),
	('00000000-0000-0000-0000-000000000000', '9eac06b5-21c2-4930-9981-b8b4c7c8c07f', '{"action":"token_revoked","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 06:08:53.338527+00', ''),
	('00000000-0000-0000-0000-000000000000', '93c7ef41-0892-4fe1-a26c-b4b57195f5fb', '{"action":"token_refreshed","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 07:12:52.608922+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e359d92d-01cc-4e00-a30c-bdf98a4f69c3', '{"action":"token_revoked","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 07:12:52.613623+00', ''),
	('00000000-0000-0000-0000-000000000000', '7de956e8-4e7c-4c80-ab35-e0c2a6e355ff', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 07:28:40.08767+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e9abdf68-87d3-4a66-880b-3c00332d0394', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 07:28:40.093361+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a85438a0-9845-46af-9bde-ea7f0069d2cc', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-11 09:32:12.671289+00', ''),
	('00000000-0000-0000-0000-000000000000', '09977cbb-8242-42f6-97c9-17a1c9d464e6', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 10:06:45.863745+00', ''),
	('00000000-0000-0000-0000-000000000000', '3b7c51c6-0562-4634-ad77-26140916c935', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 10:06:45.866277+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e3707630-cee0-4210-a29a-c6c8426390ff', '{"action":"token_refreshed","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 10:16:42.092573+00', ''),
	('00000000-0000-0000-0000-000000000000', '9a2a6fad-ca43-4501-9ec7-17b7825cdcf2', '{"action":"token_revoked","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 10:16:42.095661+00', ''),
	('00000000-0000-0000-0000-000000000000', '8d0dcb4f-8892-4f3c-921c-efcaecaa1609', '{"action":"logout","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-11 10:20:38.148044+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd03f5db0-651f-40e8-a1c7-159c66067592', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-11 10:20:42.551375+00', ''),
	('00000000-0000-0000-0000-000000000000', '48b65d6e-bb25-48e3-b23c-dd3fa95c597f', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 13:05:28.743929+00', ''),
	('00000000-0000-0000-0000-000000000000', '92ce1870-6a2a-4f64-b918-d01b1f29ac1e', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 13:05:28.746593+00', ''),
	('00000000-0000-0000-0000-000000000000', '0c169446-29c1-4452-83cc-5784c3e28f69', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 15:20:40.769654+00', ''),
	('00000000-0000-0000-0000-000000000000', '88c9aafb-9510-4e85-b147-dcd98bbb286e', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 15:20:40.779864+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f4d80db3-f3ab-4c25-87f8-ef59020af9a5', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-11 15:49:49.802121+00', ''),
	('00000000-0000-0000-0000-000000000000', '8417ce86-6739-4678-8f34-3ea2bcd53b9d', '{"action":"login","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-11 15:50:00.531646+00', ''),
	('00000000-0000-0000-0000-000000000000', '0f317b6a-b3ef-4eb3-9082-24d969dbf8b6', '{"action":"logout","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-11 15:55:15.799709+00', ''),
	('00000000-0000-0000-0000-000000000000', '77fb3a5c-d135-4bd7-ac40-53e188d7eedb', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-11 15:55:20.99849+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ea0be44b-6a22-4692-b1c0-0f9ec7a4891d', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-11 16:09:12.019679+00', ''),
	('00000000-0000-0000-0000-000000000000', '6dce2fb1-2d42-4314-b8b2-0e08f0974938', '{"action":"login","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-11 16:09:20.378604+00', ''),
	('00000000-0000-0000-0000-000000000000', '6780f7d9-7599-4a8e-be2e-ff4c71731648', '{"action":"logout","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-11 16:11:25.285756+00', ''),
	('00000000-0000-0000-0000-000000000000', '5caa5f30-d57b-43cb-bfbf-6a404f8ac4da', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-11 16:11:28.947779+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd1ecdfc5-fa15-4451-8068-9f4a08be9bb5', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-11 16:11:59.330506+00', ''),
	('00000000-0000-0000-0000-000000000000', '3faba005-7c31-4ca0-9dc0-268646a12ade', '{"action":"login","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-11 16:12:06.8029+00', ''),
	('00000000-0000-0000-0000-000000000000', '7f732a25-24dd-472b-a004-00139173243c', '{"action":"logout","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-11 16:14:11.639419+00', ''),
	('00000000-0000-0000-0000-000000000000', '4b360d51-4b0a-42b6-ae9d-47f6a694f5a0', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-11 16:14:17.277106+00', ''),
	('00000000-0000-0000-0000-000000000000', '4ab693a4-8ead-434f-bff8-ae1e24a2f79f', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 17:00:12.456753+00', ''),
	('00000000-0000-0000-0000-000000000000', '23bf5b2f-fbf3-4fe5-8fb2-93e0a3b55a8f', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 17:00:12.460892+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f4595754-8580-4840-b9dd-2f19d78c2cf5', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 17:34:04.644978+00', ''),
	('00000000-0000-0000-0000-000000000000', '1c6db185-b1be-426b-855c-b8c711c30706', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-11 17:34:04.647746+00', ''),
	('00000000-0000-0000-0000-000000000000', '516716d6-6108-475b-b5de-32491f917348', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-11 17:38:16.019551+00', ''),
	('00000000-0000-0000-0000-000000000000', '4ad63d25-0e66-4f90-9f03-a1362259bba2', '{"action":"login","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-11 17:38:29.000331+00', ''),
	('00000000-0000-0000-0000-000000000000', '196560a0-da69-48ea-9c86-fcc5d25e8c19', '{"action":"logout","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-11 17:38:33.644643+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cb141acf-a473-48aa-8399-a54697fbf448', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-11 17:38:49.008895+00', ''),
	('00000000-0000-0000-0000-000000000000', '4494cd20-82d3-4164-96ce-d493427265b2', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-11 17:39:08.149364+00', ''),
	('00000000-0000-0000-0000-000000000000', '590e02a1-0dca-4d78-8519-c7bf6d320911', '{"action":"login","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-11 17:39:16.838071+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f05a5d08-fccd-441e-95af-f32cd5fa9e4d', '{"action":"logout","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-11 17:45:17.540322+00', ''),
	('00000000-0000-0000-0000-000000000000', '9fcd9f20-d133-4dc3-b64d-9188cebe4ebc', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-11 17:45:22.743945+00', ''),
	('00000000-0000-0000-0000-000000000000', '744d0421-c183-4b0c-8650-dab160ee120d', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-11 17:45:33.023828+00', ''),
	('00000000-0000-0000-0000-000000000000', '3dd5efc2-228b-401a-85aa-bcf7e2080ffa', '{"action":"login","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-11 17:45:38.335154+00', ''),
	('00000000-0000-0000-0000-000000000000', 'abd3579a-1182-4f0d-802f-6df3c7f5dea9', '{"action":"logout","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-11 17:45:55.549745+00', ''),
	('00000000-0000-0000-0000-000000000000', '9f412b9a-81e4-413f-b843-54985b165431', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-11 17:46:00.322651+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fe62584c-703c-4518-b351-d80d72b1f90a', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-11 19:06:03.154314+00', ''),
	('00000000-0000-0000-0000-000000000000', 'aec9469f-876f-469e-ab1e-9fcb90d75076', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-12 02:28:09.221706+00', ''),
	('00000000-0000-0000-0000-000000000000', '5516d8b7-823d-44da-b5af-a45f88c474b9', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-12 02:28:09.227274+00', ''),
	('00000000-0000-0000-0000-000000000000', '362b4fbc-c8b6-47c3-acef-69c7ccd5b0eb', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-12 03:26:09.913516+00', ''),
	('00000000-0000-0000-0000-000000000000', '2dc3d499-703d-4f2b-b471-c583da7ae607', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-12 03:26:09.915623+00', ''),
	('00000000-0000-0000-0000-000000000000', '6a8abe29-a94c-40af-9c72-d97040a74f8a', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-12 07:12:47.05926+00', ''),
	('00000000-0000-0000-0000-000000000000', '27d1be9e-4a0c-41cc-a519-47739d880bd1', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-12 07:12:47.06675+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ca2c2acd-7d30-4614-b0ff-e1ac23243fb2', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-12 09:23:14.161471+00', ''),
	('00000000-0000-0000-0000-000000000000', '4b47a294-bee7-4dff-bd6d-a5f2ba103852', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-12 09:23:14.164864+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e3781a72-2d5a-4598-96a7-babfc6121f3b', '{"action":"login","actor_id":"2d15cf78-b2a0-4014-8c9e-95738b853eb9","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-12 11:33:59.725289+00', ''),
	('00000000-0000-0000-0000-000000000000', '348fcde3-88dc-4317-8e11-dbc6c1e7b037', '{"action":"logout","actor_id":"2d15cf78-b2a0-4014-8c9e-95738b853eb9","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-12 11:34:43.37448+00', ''),
	('00000000-0000-0000-0000-000000000000', '03f66d7c-326a-46d5-8adb-f7d1c4eac0ef', '{"action":"login","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-12 11:34:50.035407+00', ''),
	('00000000-0000-0000-0000-000000000000', '4bfa16c4-62a4-4c8b-b7d5-ae571e3b27d8', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-12 11:36:05.22948+00', ''),
	('00000000-0000-0000-0000-000000000000', '6b9b478f-7503-4b08-95eb-f952339eaa60', '{"action":"logout","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-12 11:36:49.594964+00', ''),
	('00000000-0000-0000-0000-000000000000', '58c11cb2-233b-4605-a850-7b4b136b0c58', '{"action":"login","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-12 11:38:03.219785+00', ''),
	('00000000-0000-0000-0000-000000000000', '7606b79f-f7a0-4fba-bbde-271a1bb02d0d', '{"action":"logout","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-12 11:39:18.069908+00', ''),
	('00000000-0000-0000-0000-000000000000', '1a299878-11ef-49e7-87ed-e2f93ca27673', '{"action":"login","actor_id":"2d15cf78-b2a0-4014-8c9e-95738b853eb9","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-12 11:39:25.837783+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a68f928a-debe-44a6-b882-7de67f53b671', '{"action":"logout","actor_id":"2d15cf78-b2a0-4014-8c9e-95738b853eb9","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-12 11:41:30.690477+00', ''),
	('00000000-0000-0000-0000-000000000000', '4d540e29-8c71-4658-bf62-fd8a0749f11f', '{"action":"login","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-12 11:41:38.096821+00', ''),
	('00000000-0000-0000-0000-000000000000', '0f10f6c0-6411-4b35-af18-7b900ea62de3', '{"action":"logout","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-12 11:44:11.329969+00', ''),
	('00000000-0000-0000-0000-000000000000', '04e762b7-3478-4aac-95b0-42e6dbbf7908', '{"action":"user_signedup","actor_id":"0de89068-d0da-47c5-964a-0a5d5da5cdd0","actor_name":"Sir Wild","actor_username":"sirwildyt@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-12 11:44:25.905794+00', ''),
	('00000000-0000-0000-0000-000000000000', '0494a954-7704-4a1e-b351-01a8890b22a4', '{"action":"token_refreshed","actor_id":"0de89068-d0da-47c5-964a-0a5d5da5cdd0","actor_name":"Sir Wild","actor_username":"sirwildyt@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-12 12:44:29.639483+00', ''),
	('00000000-0000-0000-0000-000000000000', '62f6ae45-4446-4d00-9409-e9e85940693b', '{"action":"token_revoked","actor_id":"0de89068-d0da-47c5-964a-0a5d5da5cdd0","actor_name":"Sir Wild","actor_username":"sirwildyt@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-12 12:44:29.640928+00', ''),
	('00000000-0000-0000-0000-000000000000', '5a8eacfe-c71c-4996-9fef-da7e06d26b91', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-12 13:55:52.594013+00', ''),
	('00000000-0000-0000-0000-000000000000', '1e48db96-7e00-41c7-acc4-9909a82b0519', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-12 13:55:52.612059+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c8922cfd-4919-44f6-a54a-34be8e9d72c5', '{"action":"token_refreshed","actor_id":"0de89068-d0da-47c5-964a-0a5d5da5cdd0","actor_name":"Sir Wild","actor_username":"sirwildyt@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 07:18:47.909415+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b9c66995-2da1-4cc2-b78b-6c6be0cd3698', '{"action":"token_revoked","actor_id":"0de89068-d0da-47c5-964a-0a5d5da5cdd0","actor_name":"Sir Wild","actor_username":"sirwildyt@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 07:18:47.920651+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd422c421-7932-4ed4-b645-b6354cb95c38', '{"action":"user_confirmation_requested","actor_id":"df1d2f97-8f64-4160-a909-9039e6619ae3","actor_username":"psihologandreeadianaion@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-13 07:49:31.685546+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a9fbf6fd-3886-4b02-8acb-4cc38fbec507', '{"action":"user_signedup","actor_id":"df1d2f97-8f64-4160-a909-9039e6619ae3","actor_username":"psihologandreeadianaion@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-13 07:50:54.267439+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e77c8c96-416c-4927-ad5b-84f52243dd95', '{"action":"logout","actor_id":"df1d2f97-8f64-4160-a909-9039e6619ae3","actor_username":"psihologandreeadianaion@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-13 07:51:41.258268+00', ''),
	('00000000-0000-0000-0000-000000000000', '0106caaa-222b-417e-b04a-2bae52f1d725', '{"action":"login","actor_id":"df1d2f97-8f64-4160-a909-9039e6619ae3","actor_username":"psihologandreeadianaion@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-13 07:51:44.606946+00', ''),
	('00000000-0000-0000-0000-000000000000', '8c80e620-ada4-485f-bd57-598ba6f6ee3b', '{"action":"user_signedup","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-13 08:06:36.862409+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b50e0b3a-def7-4442-9ffc-353a0d862cfe', '{"action":"login","actor_id":"df1d2f97-8f64-4160-a909-9039e6619ae3","actor_username":"psihologandreeadianaion@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-13 08:15:14.666135+00', ''),
	('00000000-0000-0000-0000-000000000000', 'de36feb4-4136-4e08-8c99-d149fa4526fc', '{"action":"user_confirmation_requested","actor_id":"3497971b-b2c2-4a3a-9a42-420d8a26faec","actor_username":"kis.monica@yahoo.it","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-13 08:18:59.057184+00', ''),
	('00000000-0000-0000-0000-000000000000', '4f41f84b-fbf9-4e0c-a2da-a7ce186b5adc', '{"action":"user_signedup","actor_id":"3497971b-b2c2-4a3a-9a42-420d8a26faec","actor_username":"kis.monica@yahoo.it","actor_via_sso":false,"log_type":"team"}', '2025-05-13 08:19:08.55108+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a856f38e-a0f4-43f4-9ee3-d86c37a511f7', '{"action":"user_confirmation_requested","actor_id":"aa3c7129-7b21-49e5-b099-19fa2ef0c95f","actor_username":"amaliacosma@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-13 08:19:48.401808+00', ''),
	('00000000-0000-0000-0000-000000000000', '97957446-2c77-473b-af27-a400bceec4f0', '{"action":"user_confirmation_requested","actor_id":"aa3c7129-7b21-49e5-b099-19fa2ef0c95f","actor_username":"amaliacosma@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-13 08:22:58.945319+00', ''),
	('00000000-0000-0000-0000-000000000000', '17f0a108-5b37-4703-b352-0986069c4135', '{"action":"user_signedup","actor_id":"aa3c7129-7b21-49e5-b099-19fa2ef0c95f","actor_username":"amaliacosma@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-13 08:23:24.347858+00', ''),
	('00000000-0000-0000-0000-000000000000', '61a1a49b-c788-46b5-9607-859ab5662996', '{"action":"login","actor_id":"aa3c7129-7b21-49e5-b099-19fa2ef0c95f","actor_name":"Amalia Tamas","actor_username":"amaliacosma@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-13 08:25:05.010354+00', ''),
	('00000000-0000-0000-0000-000000000000', '6bdf7c7b-987f-448a-95c1-5f9e5c7ce717', '{"action":"user_confirmation_requested","actor_id":"dee01008-065a-4255-99b7-b09a5f8e646a","actor_username":"andreeacira@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-13 08:47:37.511313+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c77a654b-16ef-4ac3-9ecc-9e7ade07aa7e', '{"action":"login","actor_id":"2d15cf78-b2a0-4014-8c9e-95738b853eb9","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-13 08:51:42.912175+00', ''),
	('00000000-0000-0000-0000-000000000000', '0628d17f-061e-444e-affa-854ce71d0482', '{"action":"logout","actor_id":"2d15cf78-b2a0-4014-8c9e-95738b853eb9","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-13 08:51:53.744594+00', ''),
	('00000000-0000-0000-0000-000000000000', 'be282c25-b176-4a27-a9d1-3a78238eb78b', '{"action":"login","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-13 08:51:59.175901+00', ''),
	('00000000-0000-0000-0000-000000000000', 'aaa3a775-e2a4-43e9-b68d-57012ba8d035', '{"action":"user_confirmation_requested","actor_id":"dee01008-065a-4255-99b7-b09a5f8e646a","actor_username":"andreeacira@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-13 08:55:44.956828+00', ''),
	('00000000-0000-0000-0000-000000000000', '1d4af7ec-2d77-4766-b55f-3610eccc6700', '{"action":"user_signedup","actor_id":"dee01008-065a-4255-99b7-b09a5f8e646a","actor_username":"andreeacira@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-13 08:56:07.983959+00', ''),
	('00000000-0000-0000-0000-000000000000', '9654e749-0d00-457e-b412-b97c91b31935', '{"action":"token_refreshed","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 09:05:23.156228+00', ''),
	('00000000-0000-0000-0000-000000000000', '0bae3b1e-cc65-49e6-b8f6-52264a1bd508', '{"action":"token_revoked","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 09:05:23.157104+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f6124fc1-b978-4698-b404-d43c59ce9b68', '{"action":"logout","actor_id":"dee01008-065a-4255-99b7-b09a5f8e646a","actor_username":"andreeacira@yahoo.com","actor_via_sso":false,"log_type":"account"}', '2025-05-13 09:21:18.23397+00', ''),
	('00000000-0000-0000-0000-000000000000', '78834524-bae9-400b-991a-5c4e7f6d275a', '{"action":"user_signedup","actor_id":"e1ca682f-8dd7-4399-b622-4408513c1c11","actor_name":"Adriana Știube","actor_username":"psiho.adrianastiube@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-13 09:32:59.596531+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e9597c71-ba2a-4610-a7d7-5ece44a9c104', '{"action":"user_confirmation_requested","actor_id":"89b950c9-a55e-4747-abf4-e403523289d4","actor_username":"iulia0475@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-13 10:07:13.4835+00', ''),
	('00000000-0000-0000-0000-000000000000', '149bb64b-5da5-4abc-905a-742c5052afd7', '{"action":"user_confirmation_requested","actor_id":"89b950c9-a55e-4747-abf4-e403523289d4","actor_username":"iulia0475@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-13 10:08:33.852917+00', ''),
	('00000000-0000-0000-0000-000000000000', '16cfd63d-d43e-4e82-8b78-3d961b87ed08', '{"action":"user_confirmation_requested","actor_id":"a830c1a7-13ce-4c8f-96fa-4c7c7bb4085e","actor_username":"alexandru_georgian09@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-13 11:28:43.191057+00', ''),
	('00000000-0000-0000-0000-000000000000', '4419649a-f900-4d1a-83b7-f4d8c8af847b', '{"action":"user_signedup","actor_id":"a830c1a7-13ce-4c8f-96fa-4c7c7bb4085e","actor_username":"alexandru_georgian09@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-13 11:29:32.745863+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c8a1d2d6-a1b7-4264-90be-92630a978977', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 12:14:40.286521+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cd744bf7-ec26-4326-ace1-df0324c5e902', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 12:43:49.381182+00', ''),
	('00000000-0000-0000-0000-000000000000', '7df78dde-dd78-41fb-ab2a-ac273a0c4947', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 12:43:49.383134+00', ''),
	('00000000-0000-0000-0000-000000000000', '936b3a37-9faf-46ab-b1ef-aa104cb95f0f', '{"action":"user_confirmation_requested","actor_id":"12389e53-ab41-4ff5-90ee-c3593e2b84cc","actor_username":"andriescu.diana98@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-13 14:50:53.665263+00', ''),
	('00000000-0000-0000-0000-000000000000', '405154ee-e27c-447f-89aa-d29136ea7190', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 14:57:22.981152+00', ''),
	('00000000-0000-0000-0000-000000000000', '50df05ee-4ad2-408f-8a16-83fe8b2fa3a7', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 14:57:22.983515+00', ''),
	('00000000-0000-0000-0000-000000000000', '6ec7d227-262b-48ef-a20b-36b9eae97393', '{"action":"token_refreshed","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 14:59:37.063901+00', ''),
	('00000000-0000-0000-0000-000000000000', '2815b6bc-7179-44eb-aaf0-ad9ae264579d', '{"action":"token_revoked","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 14:59:37.06556+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b1ab7018-f09b-42bb-8215-45db037f5052', '{"action":"user_confirmation_requested","actor_id":"12389e53-ab41-4ff5-90ee-c3593e2b84cc","actor_username":"andriescu.diana98@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-13 15:52:44.878665+00', ''),
	('00000000-0000-0000-0000-000000000000', '0c828beb-4bf8-4756-9d91-d51784a8f8e9', '{"action":"user_signedup","actor_id":"12389e53-ab41-4ff5-90ee-c3593e2b84cc","actor_name":"ANDRIESCU DIANA","actor_username":"andriescu.diana98@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-13 15:56:43.190841+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b6a78de9-f4a4-47fa-a38c-57cff35249a8', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 16:26:49.634322+00', ''),
	('00000000-0000-0000-0000-000000000000', '1d86def7-e21b-4b07-b7f9-28bb4dec8afc', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 16:26:49.636084+00', ''),
	('00000000-0000-0000-0000-000000000000', '39d6aec8-e58a-4481-87a5-069b12059a38', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 17:24:52.616486+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e11367c1-6373-4184-846c-be4ae851ce6d', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 17:24:52.618802+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fc77d15b-2b3e-4c5b-954a-b681693b7b45', '{"action":"token_refreshed","actor_id":"12389e53-ab41-4ff5-90ee-c3593e2b84cc","actor_name":"ANDRIESCU DIANA","actor_username":"andriescu.diana98@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 17:26:12.778577+00', ''),
	('00000000-0000-0000-0000-000000000000', '867f6292-41aa-4664-a99a-4442c846681f', '{"action":"token_revoked","actor_id":"12389e53-ab41-4ff5-90ee-c3593e2b84cc","actor_name":"ANDRIESCU DIANA","actor_username":"andriescu.diana98@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-13 17:26:12.780214+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f23deb94-a240-40a2-9d7b-88e3ba87fd55', '{"action":"user_signedup","actor_id":"c07e8742-9b26-4257-80d8-81ea920e3722","actor_name":"Cristina Buzea","actor_username":"cbuzea30@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-13 18:37:38.500798+00', ''),
	('00000000-0000-0000-0000-000000000000', '9b6e455e-5fff-4582-8a04-8f48dc4f2753', '{"action":"login","actor_id":"c07e8742-9b26-4257-80d8-81ea920e3722","actor_name":"Cristina Buzea","actor_username":"cbuzea30@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-13 20:01:00.462175+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c5c3de65-a93e-427e-a4dd-0eafb9d7601a', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 00:59:10.088395+00', ''),
	('00000000-0000-0000-0000-000000000000', '202704b7-ab51-4279-b9f7-018b3abafd35', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 00:59:10.09162+00', ''),
	('00000000-0000-0000-0000-000000000000', '2430f043-f9ff-4c03-bb4f-e81a6d0d9563', '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role","actor_via_sso":false,"log_type":"team","traits":{"user_email":"andreeacira@yahoo.com","user_id":"dee01008-065a-4255-99b7-b09a5f8e646a","user_phone":""}}', '2025-05-14 01:05:11.666063+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a9c3103c-5c0f-4893-bd59-769b47db7701', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 01:34:01.26203+00', ''),
	('00000000-0000-0000-0000-000000000000', '4ed99f1a-21d3-412e-86b8-8bf30fb36b52', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 01:34:01.264943+00', ''),
	('00000000-0000-0000-0000-000000000000', '723ae2df-08de-4c32-9001-534a935de564', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 02:36:48.096231+00', ''),
	('00000000-0000-0000-0000-000000000000', '177e7937-f8f6-4d4a-9b11-90d9eda59e58', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 02:36:48.099327+00', ''),
	('00000000-0000-0000-0000-000000000000', '380998b1-0d8d-4335-aa2e-0749ced66168', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 02:37:26.861774+00', ''),
	('00000000-0000-0000-0000-000000000000', '4a161fe2-fc90-43b1-a2d2-3faf426a5bd0', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 02:37:26.862413+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd8f3e661-2951-470e-a711-ce703e104210', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 03:35:17.49028+00', ''),
	('00000000-0000-0000-0000-000000000000', '0fed9083-9fc4-4358-a9e1-9678ec33e3ab', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 03:35:17.491779+00', ''),
	('00000000-0000-0000-0000-000000000000', '5435035b-f353-4977-8765-1adc6c42fffc', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-14 03:53:34.644004+00', ''),
	('00000000-0000-0000-0000-000000000000', '297cc1fd-5997-4455-9e09-9e022891b82e', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-14 05:35:43.907833+00', ''),
	('00000000-0000-0000-0000-000000000000', '781c956d-a394-4b44-816d-69f059ecf231', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-14 05:51:56.761516+00', ''),
	('00000000-0000-0000-0000-000000000000', '0484058b-ce66-4343-bdd2-257dfde0fab5', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-14 06:05:37.324388+00', ''),
	('00000000-0000-0000-0000-000000000000', '1a161f1d-03c3-4489-8c89-f4a952eda37e', '{"action":"login","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-14 06:42:37.113955+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c1afc911-82f0-4b9d-8d71-1d2c7df37ac5', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 07:04:22.997478+00', ''),
	('00000000-0000-0000-0000-000000000000', '990ec4d7-dfa3-41a3-a8f7-c8861bc77b9a', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 07:04:22.999071+00', ''),
	('00000000-0000-0000-0000-000000000000', '0be689ef-f3fb-4b46-be22-b503d51613ec', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-14 07:21:59.989644+00', ''),
	('00000000-0000-0000-0000-000000000000', '2ccbf961-c23d-4aa3-b6e8-d83c1b002d09', '{"action":"user_signedup","actor_id":"c23140ab-5bf3-4a7a-a80b-fcb8b9dcb8a4","actor_name":"Raul","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-14 07:30:03.619887+00', ''),
	('00000000-0000-0000-0000-000000000000', '41e858a7-de02-440e-b064-7eae707c3961', '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role","actor_via_sso":false,"log_type":"team","traits":{"user_email":"secrets.of.life.f2p@gmail.com","user_id":"c23140ab-5bf3-4a7a-a80b-fcb8b9dcb8a4","user_phone":""}}', '2025-05-14 07:36:22.876546+00', ''),
	('00000000-0000-0000-0000-000000000000', '3ca37327-4483-4747-9891-934162765af8', '{"action":"user_confirmation_requested","actor_id":"ba8784c6-20e5-4a28-ada7-6aa18b5a53bb","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-14 07:36:43.247657+00', ''),
	('00000000-0000-0000-0000-000000000000', '7c981971-2115-4042-b45f-2d390ad8cdde', '{"action":"user_signedup","actor_id":"ba8784c6-20e5-4a28-ada7-6aa18b5a53bb","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-14 07:36:48.645723+00', ''),
	('00000000-0000-0000-0000-000000000000', '63f8e93f-692b-4822-868b-65b06c49a021', '{"action":"login","actor_id":"ba8784c6-20e5-4a28-ada7-6aa18b5a53bb","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-14 07:36:57.18455+00', ''),
	('00000000-0000-0000-0000-000000000000', '65ce0f58-5756-4b2f-8a14-fd65a134826a', '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role","actor_via_sso":false,"log_type":"team","traits":{"user_email":"secrets.of.life.f2p@gmail.com","user_id":"ba8784c6-20e5-4a28-ada7-6aa18b5a53bb","user_phone":""}}', '2025-05-14 07:51:17.316479+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ca9d9751-4c45-4b18-9bc2-d20634631ed6', '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role","actor_via_sso":false,"log_type":"team","traits":{"user_email":"baciu.raul555@gmail.com","user_id":"c1875f81-a33c-4f5d-9278-2969d1ef4ef5","user_phone":""}}', '2025-05-14 07:52:28.032227+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c6c2e0b1-d1fd-4f33-bcdd-597e1cf8b35f', '{"action":"user_confirmation_requested","actor_id":"001e2438-5211-4fed-92c8-cc22f129bc06","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-14 08:00:53.410757+00', ''),
	('00000000-0000-0000-0000-000000000000', '4beb5fc9-44de-4a13-ba8d-5f7423bfa1b0', '{"action":"user_signedup","actor_id":"001e2438-5211-4fed-92c8-cc22f129bc06","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-14 08:01:17.334252+00', ''),
	('00000000-0000-0000-0000-000000000000', '5e1332ab-69f4-4d51-8185-2fc72510e8fa', '{"action":"logout","actor_id":"001e2438-5211-4fed-92c8-cc22f129bc06","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-14 08:03:22.454797+00', ''),
	('00000000-0000-0000-0000-000000000000', '76214ab3-76c8-4145-b26f-29bb4479e117', '{"action":"user_signedup","actor_id":"b0a95dc5-f10a-4ec0-8012-340b7ff82d15","actor_name":"Baciu Raul","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-14 08:03:29.344456+00', ''),
	('00000000-0000-0000-0000-000000000000', '6c1fd4c6-aff9-4fbb-9a65-8a75760ec79f', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 09:58:52.461869+00', ''),
	('00000000-0000-0000-0000-000000000000', '64bec696-0809-4a3a-8adb-9ebe78f55005', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 09:58:52.46394+00', ''),
	('00000000-0000-0000-0000-000000000000', '106bed5d-6794-46f8-917e-060764f70997', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 11:44:02.319821+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ef4c95cb-2e43-4448-a75d-5445e16a251b', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 11:44:02.322341+00', ''),
	('00000000-0000-0000-0000-000000000000', '24bcc918-3b10-499b-9f9d-37bbfc5fc9f2', '{"action":"token_refreshed","actor_id":"c07e8742-9b26-4257-80d8-81ea920e3722","actor_name":"Cristina Buzea","actor_username":"cbuzea30@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 12:53:00.606284+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd53df393-4739-4c65-ae61-fe9d1205264b', '{"action":"token_revoked","actor_id":"c07e8742-9b26-4257-80d8-81ea920e3722","actor_name":"Cristina Buzea","actor_username":"cbuzea30@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 12:53:00.61425+00', ''),
	('00000000-0000-0000-0000-000000000000', '6e4ccff8-5041-4571-8a3d-cbc102ace214', '{"action":"token_refreshed","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 13:10:13.15496+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dcf3128c-0292-45da-8aea-f12b3e46a8e9', '{"action":"token_revoked","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 13:10:13.157408+00', ''),
	('00000000-0000-0000-0000-000000000000', '9265b855-6dcc-414b-aac8-7b8812ed924d', '{"action":"login","actor_id":"12389e53-ab41-4ff5-90ee-c3593e2b84cc","actor_name":"ANDRIESCU DIANA","actor_username":"andriescu.diana98@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-14 13:45:20.167065+00', ''),
	('00000000-0000-0000-0000-000000000000', '23e8ef7a-a109-403c-a5a5-c7ece20a8d1d', '{"action":"login","actor_id":"001e2438-5211-4fed-92c8-cc22f129bc06","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-14 14:42:08.65924+00', ''),
	('00000000-0000-0000-0000-000000000000', '1ca99a1d-31ad-4fa9-b657-8f4176517284', '{"action":"logout","actor_id":"001e2438-5211-4fed-92c8-cc22f129bc06","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-14 14:43:54.087768+00', ''),
	('00000000-0000-0000-0000-000000000000', '8c8b3594-a93d-4d95-80d1-8a29b5bbf2e4', '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role","actor_via_sso":false,"log_type":"team","traits":{"user_email":"secrets.of.life.f2p@gmail.com","user_id":"001e2438-5211-4fed-92c8-cc22f129bc06","user_phone":""}}', '2025-05-14 14:45:14.041637+00', ''),
	('00000000-0000-0000-0000-000000000000', '180d313b-86f2-41d8-8924-fd8cd44ad04e', '{"action":"user_confirmation_requested","actor_id":"5770b09e-2db8-4da1-ab21-381f6057a549","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-14 14:45:31.510984+00', ''),
	('00000000-0000-0000-0000-000000000000', '57c03ef5-9858-4d4a-ac29-8f98c8ea6b71', '{"action":"user_confirmation_requested","actor_id":"5770b09e-2db8-4da1-ab21-381f6057a549","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-14 14:59:15.476763+00', ''),
	('00000000-0000-0000-0000-000000000000', '553305dc-97aa-4abd-9a5f-3f5d2ce1e159', '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role","actor_via_sso":false,"log_type":"team","traits":{"user_email":"secrets.of.life.f2p@gmail.com","user_id":"5770b09e-2db8-4da1-ab21-381f6057a549","user_phone":""}}', '2025-05-14 15:04:27.653058+00', ''),
	('00000000-0000-0000-0000-000000000000', '040f3d16-db7d-4d7b-b0b5-e53876ed41fa', '{"action":"user_confirmation_requested","actor_id":"4a645dc4-f40a-455c-a745-5135720c1625","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-14 15:05:45.048554+00', ''),
	('00000000-0000-0000-0000-000000000000', '61c31fe4-6c02-4a4d-8168-14139fff4443', '{"action":"user_confirmation_requested","actor_id":"4a645dc4-f40a-455c-a745-5135720c1625","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-14 15:19:25.716755+00', ''),
	('00000000-0000-0000-0000-000000000000', '05854399-2327-4918-a151-0cd14d6fbb24', '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role","actor_via_sso":false,"log_type":"team","traits":{"user_email":"secrets.of.life.f2p@gmail.com","user_id":"4a645dc4-f40a-455c-a745-5135720c1625","user_phone":""}}', '2025-05-14 15:20:36.780991+00', ''),
	('00000000-0000-0000-0000-000000000000', '1236535e-4475-454f-8aac-db7a64dbb899', '{"action":"user_confirmation_requested","actor_id":"a465136d-7cfe-4987-bb2d-1bda3d02a436","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-14 15:20:49.595768+00', ''),
	('00000000-0000-0000-0000-000000000000', 'da5d4d5a-f80c-46c0-9a4e-adb41e989dfe', '{"action":"user_confirmation_requested","actor_id":"a465136d-7cfe-4987-bb2d-1bda3d02a436","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"user"}', '2025-05-14 15:22:37.115619+00', ''),
	('00000000-0000-0000-0000-000000000000', '8ffd4ad8-0ca0-4da1-8ee8-19eada461d99', '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role","actor_via_sso":false,"log_type":"team","traits":{"user_email":"secrets.of.life.f2p@gmail.com","user_id":"a465136d-7cfe-4987-bb2d-1bda3d02a436","user_phone":""}}', '2025-05-14 15:25:47.39264+00', ''),
	('00000000-0000-0000-0000-000000000000', '148c0371-c7f4-4113-8b3f-eb1a69fdf68c', '{"action":"user_confirmation_requested","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-14 15:26:28.235109+00', ''),
	('00000000-0000-0000-0000-000000000000', '76968809-f9f1-4976-83a9-12740c007f72', '{"action":"user_confirmation_requested","actor_id":"f10db344-d6f0-4ae3-8ea0-4b1cb2a80894","actor_username":"psiholog.denisapopescu@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-14 15:26:57.184756+00', ''),
	('00000000-0000-0000-0000-000000000000', '1e41d64d-d8eb-4a0c-8661-c65cd5172183', '{"action":"user_signedup","actor_id":"f10db344-d6f0-4ae3-8ea0-4b1cb2a80894","actor_username":"psiholog.denisapopescu@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-14 15:29:28.345359+00', ''),
	('00000000-0000-0000-0000-000000000000', '2e5dd11e-3b81-4d9f-9a96-a6eea65d5353', '{"action":"login","actor_id":"f10db344-d6f0-4ae3-8ea0-4b1cb2a80894","actor_username":"psiholog.denisapopescu@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-14 15:29:53.104048+00', ''),
	('00000000-0000-0000-0000-000000000000', '0656fdaf-8d4f-4d39-9926-d9bf7f8e8a0c', '{"action":"user_signedup","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-14 15:37:03.973777+00', ''),
	('00000000-0000-0000-0000-000000000000', '0a7e2adb-e88d-439e-af1a-53c2d9376778', '{"action":"logout","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-14 15:41:57.655361+00', ''),
	('00000000-0000-0000-0000-000000000000', '7ae14f39-7c83-417f-9efc-1a35e5d87acc', '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role","actor_via_sso":false,"log_type":"team","traits":{"user_email":"baciu.raul555@gmail.com","user_id":"b0a95dc5-f10a-4ec0-8012-340b7ff82d15","user_phone":""}}', '2025-05-14 16:53:14.809526+00', ''),
	('00000000-0000-0000-0000-000000000000', '35d0da1b-7be1-4ef8-9780-86dbd4b42a88', '{"action":"user_signedup","actor_id":"8aa1791f-a04d-4076-8d1d-0f69e1065f34","actor_name":"Baciu Raul","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-14 16:53:21.479782+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f8355301-8137-430d-86a9-c8e3401e15cb', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-14 17:03:21.397179+00', ''),
	('00000000-0000-0000-0000-000000000000', '7a24ab6e-5c6e-40c6-af1c-198a1a7b4f60', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 17:20:17.641221+00', ''),
	('00000000-0000-0000-0000-000000000000', '1a1b68dc-9c7b-4f8c-b73b-b305de93a705', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 17:20:17.643955+00', ''),
	('00000000-0000-0000-0000-000000000000', '4dfb84a2-24e7-4051-acc1-f0e7583619e1', '{"action":"token_refreshed","actor_id":"f10db344-d6f0-4ae3-8ea0-4b1cb2a80894","actor_username":"psiholog.denisapopescu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 17:39:50.873919+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c2ef96de-c35e-4e5c-a0e7-9ad25951a18b', '{"action":"token_revoked","actor_id":"f10db344-d6f0-4ae3-8ea0-4b1cb2a80894","actor_username":"psiholog.denisapopescu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 17:39:50.876266+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ff8e89bc-9c86-4d2c-8a73-3ab3a9807ace', '{"action":"token_refreshed","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 18:17:48.442658+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e4560d5e-12fc-4d4b-bf78-d71952eae43a', '{"action":"token_revoked","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-14 18:17:48.444725+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd464e8a2-21e2-4216-bcc2-92483f56a759', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 05:33:50.888253+00', ''),
	('00000000-0000-0000-0000-000000000000', '4cdc8a26-ad97-4ab4-b32a-abb0b2ae5729', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 05:33:50.892976+00', ''),
	('00000000-0000-0000-0000-000000000000', '7fb6e2e0-f298-4e91-9f26-5ef2f842fc5c', '{"action":"logout","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-15 05:34:00.823626+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b9428940-a60a-411c-a785-6e0a5609a1f8', '{"action":"token_refreshed","actor_id":"0de89068-d0da-47c5-964a-0a5d5da5cdd0","actor_name":"Sir Wild","actor_username":"sirwildyt@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 06:23:03.01141+00', ''),
	('00000000-0000-0000-0000-000000000000', '4cee176f-bc6e-4536-abf2-5d2ecb2f76b0', '{"action":"token_revoked","actor_id":"0de89068-d0da-47c5-964a-0a5d5da5cdd0","actor_name":"Sir Wild","actor_username":"sirwildyt@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 06:23:03.015179+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c78aa01a-98dc-4725-8d8e-328a416018f4', '{"action":"logout","actor_id":"0de89068-d0da-47c5-964a-0a5d5da5cdd0","actor_name":"Sir Wild","actor_username":"sirwildyt@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-15 06:23:11.943318+00', ''),
	('00000000-0000-0000-0000-000000000000', '022f1710-eca3-43d3-8fde-951a9c566515', '{"action":"user_signedup","actor_id":"7733575e-14a6-48a4-bf21-b7901b8d6714","actor_name":"Alex Suciaghi","actor_username":"suciaghialexandrushorts@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-15 06:23:30.379434+00', ''),
	('00000000-0000-0000-0000-000000000000', '1b194200-6398-4b73-8810-5dae462bbe7c', '{"action":"user_confirmation_requested","actor_id":"433c694d-a26a-44cb-84cc-45f84d7daf07","actor_username":"camyblaga@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-15 06:35:23.706392+00', ''),
	('00000000-0000-0000-0000-000000000000', '04112d47-dda7-4a47-8c04-0660b3187099', '{"action":"user_confirmation_requested","actor_id":"8e441edf-2d91-4551-a4e6-924316cd2090","actor_username":"contactandreigeorge@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-15 06:35:50.190858+00', ''),
	('00000000-0000-0000-0000-000000000000', '79bb5e9e-0a6e-41bd-83fa-46e38cc1771a', '{"action":"user_signedup","actor_id":"433c694d-a26a-44cb-84cc-45f84d7daf07","actor_username":"camyblaga@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-15 06:35:52.213492+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f75775f7-080b-43ab-af72-d582bf9d6ac3', '{"action":"user_signedup","actor_id":"8e441edf-2d91-4551-a4e6-924316cd2090","actor_username":"contactandreigeorge@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-15 06:36:21.739772+00', ''),
	('00000000-0000-0000-0000-000000000000', '50c4783d-a6dd-403f-928b-20093460c73e', '{"action":"token_refreshed","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 07:09:09.843494+00', ''),
	('00000000-0000-0000-0000-000000000000', '485ae60d-8fbc-472e-8e03-7a38daf92c62', '{"action":"token_revoked","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 07:09:09.846493+00', ''),
	('00000000-0000-0000-0000-000000000000', '6dfa2cc5-1f85-4b7b-b35a-43b45385c30b', '{"action":"login","actor_id":"433c694d-a26a-44cb-84cc-45f84d7daf07","actor_username":"camyblaga@yahoo.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-15 07:12:49.629691+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b56b3b55-3a80-41bd-9850-09095052ebd5', '{"action":"user_confirmation_requested","actor_id":"1d4e4d74-493a-4758-a5e1-3229a81bae5d","actor_username":"inna.medeea.lupu@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-15 08:07:38.518421+00', ''),
	('00000000-0000-0000-0000-000000000000', 'eb3d96ff-a229-4129-ae58-81d8116dd75d', '{"action":"user_signedup","actor_id":"1d4e4d74-493a-4758-a5e1-3229a81bae5d","actor_username":"inna.medeea.lupu@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-15 08:09:35.078693+00', ''),
	('00000000-0000-0000-0000-000000000000', '36718e44-20d2-4589-acf7-3cb6a7367fbf', '{"action":"login","actor_id":"1d4e4d74-493a-4758-a5e1-3229a81bae5d","actor_username":"inna.medeea.lupu@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-15 08:20:41.389692+00', ''),
	('00000000-0000-0000-0000-000000000000', '9d0ce15c-5b30-4b3b-b4b0-b3497c090e7d', '{"action":"user_signedup","actor_id":"1375c34c-1b05-438e-8f4f-eeb5f0d373f8","actor_name":"Valentin Pascariu","actor_username":"valentinpascariu85@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-15 09:53:23.150978+00', ''),
	('00000000-0000-0000-0000-000000000000', '9c201329-90b3-42e7-ab26-3bb82ee50022', '{"action":"token_refreshed","actor_id":"8e441edf-2d91-4551-a4e6-924316cd2090","actor_username":"contactandreigeorge@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 10:03:29.52995+00', ''),
	('00000000-0000-0000-0000-000000000000', '8346e2d0-024b-42da-b385-26afafe60727', '{"action":"token_revoked","actor_id":"8e441edf-2d91-4551-a4e6-924316cd2090","actor_username":"contactandreigeorge@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 10:03:29.532602+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f796e3a8-e1fd-4d9d-9a0c-2b7f347705cb', '{"action":"token_refreshed","actor_id":"8aa1791f-a04d-4076-8d1d-0f69e1065f34","actor_name":"Baciu Raul","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 11:00:10.624218+00', ''),
	('00000000-0000-0000-0000-000000000000', '037d1aaf-2a03-45bd-81aa-7da7270103c3', '{"action":"token_revoked","actor_id":"8aa1791f-a04d-4076-8d1d-0f69e1065f34","actor_name":"Baciu Raul","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 11:00:10.625869+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ee84efb9-e87b-48f7-a079-65234aed8cf4', '{"action":"token_refreshed","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 11:32:34.603528+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b7824f54-1c7e-40b3-88da-599b5cb7508a', '{"action":"token_revoked","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 11:32:34.605307+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b1f9fd47-9c2b-4abf-9837-8f573bfa2ee6', '{"action":"user_confirmation_requested","actor_id":"07a95865-754b-4fed-ae0a-d4b69c486190","actor_username":"carmendadu@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-15 12:21:19.352924+00', ''),
	('00000000-0000-0000-0000-000000000000', '4b3929b2-41e4-4e6c-9193-7e4b7fb01b2a', '{"action":"user_signedup","actor_id":"07a95865-754b-4fed-ae0a-d4b69c486190","actor_username":"carmendadu@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-15 12:21:29.346456+00', ''),
	('00000000-0000-0000-0000-000000000000', '47b631a1-65a3-4824-89b4-afd2e7a583f0', '{"action":"token_refreshed","actor_id":"8aa1791f-a04d-4076-8d1d-0f69e1065f34","actor_name":"Baciu Raul","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 12:44:04.825668+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e27ceb11-f3e6-4685-8833-dac28f951c8a', '{"action":"token_revoked","actor_id":"8aa1791f-a04d-4076-8d1d-0f69e1065f34","actor_name":"Baciu Raul","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 12:44:04.827883+00', ''),
	('00000000-0000-0000-0000-000000000000', '16e2ae19-30c9-4a70-8d03-7e30b41e5519', '{"action":"token_refreshed","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 12:47:43.903756+00', ''),
	('00000000-0000-0000-0000-000000000000', 'bf5fbb81-b802-4e7a-884f-591bc2a09340', '{"action":"token_revoked","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 12:47:43.90633+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f11ecdab-cfcb-470e-b0c9-da116a530548', '{"action":"login","actor_id":"07a95865-754b-4fed-ae0a-d4b69c486190","actor_username":"carmendadu@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-15 13:06:21.690887+00', ''),
	('00000000-0000-0000-0000-000000000000', '1dcadfe1-544a-471a-adc5-ad439b7293c7', '{"action":"user_confirmation_requested","actor_id":"f9a83a83-6324-46d1-9e75-3eddf8edd890","actor_username":"anghelescucodrutvictor@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-15 13:48:04.891366+00', ''),
	('00000000-0000-0000-0000-000000000000', '0efbf29e-597a-4995-a5c5-6f23be1d53b4', '{"action":"user_signedup","actor_id":"f9a83a83-6324-46d1-9e75-3eddf8edd890","actor_username":"anghelescucodrutvictor@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-15 13:48:19.406926+00', ''),
	('00000000-0000-0000-0000-000000000000', '721d8f3a-a2b3-41e5-a14f-ffb277a1c2a2', '{"action":"token_refreshed","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 14:01:53.424674+00', ''),
	('00000000-0000-0000-0000-000000000000', '2588d88a-453c-47fc-9547-e02517cfba25', '{"action":"token_revoked","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 14:01:53.428058+00', ''),
	('00000000-0000-0000-0000-000000000000', '97031437-3bec-45af-9545-dacbd28a2210', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-15 14:13:09.592328+00', ''),
	('00000000-0000-0000-0000-000000000000', '439b67f7-f414-4479-90dd-dba282ba5768', '{"action":"token_refreshed","actor_id":"1375c34c-1b05-438e-8f4f-eeb5f0d373f8","actor_name":"Valentin Pascariu","actor_username":"valentinpascariu85@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 14:27:57.532754+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd80291fe-e489-4b24-9950-1cd65fcb56c3', '{"action":"token_revoked","actor_id":"1375c34c-1b05-438e-8f4f-eeb5f0d373f8","actor_name":"Valentin Pascariu","actor_username":"valentinpascariu85@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 14:27:57.534843+00', ''),
	('00000000-0000-0000-0000-000000000000', '3a7cad6d-f236-4705-a1e9-07bccad189e4', '{"action":"token_refreshed","actor_id":"8aa1791f-a04d-4076-8d1d-0f69e1065f34","actor_name":"Baciu Raul","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 14:44:31.646773+00', ''),
	('00000000-0000-0000-0000-000000000000', '379bc60f-3f33-4acb-a448-de4f7c7687c6', '{"action":"token_revoked","actor_id":"8aa1791f-a04d-4076-8d1d-0f69e1065f34","actor_name":"Baciu Raul","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 14:44:31.648602+00', ''),
	('00000000-0000-0000-0000-000000000000', '0766d49d-461a-446e-b5ed-2352d53ce28a', '{"action":"token_refreshed","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 15:02:00.910967+00', ''),
	('00000000-0000-0000-0000-000000000000', '4c6f3dad-726c-4bf6-8828-2ef360ceb391', '{"action":"token_revoked","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 15:02:00.913078+00', ''),
	('00000000-0000-0000-0000-000000000000', '204489fc-7919-4552-85d6-ee7d83255619', '{"action":"token_refreshed","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 15:33:30.769197+00', ''),
	('00000000-0000-0000-0000-000000000000', '6380dba2-13f1-4502-8639-ea1fa397b41c', '{"action":"token_revoked","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 15:33:30.770947+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a7483c23-9bc8-476d-b69b-c27c9eb683a0', '{"action":"token_refreshed","actor_id":"f9a83a83-6324-46d1-9e75-3eddf8edd890","actor_username":"anghelescucodrutvictor@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 15:49:31.305353+00', ''),
	('00000000-0000-0000-0000-000000000000', '80cdc1ad-7823-4c3a-8861-ae2e1f3c93de', '{"action":"token_revoked","actor_id":"f9a83a83-6324-46d1-9e75-3eddf8edd890","actor_username":"anghelescucodrutvictor@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 15:49:31.307082+00', ''),
	('00000000-0000-0000-0000-000000000000', '9a8f6383-e859-49a2-90c5-92e861f4d5d0', '{"action":"token_refreshed","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 16:00:31.356435+00', ''),
	('00000000-0000-0000-0000-000000000000', '4043c674-a8cc-4fd3-86c1-cfd8f4593053', '{"action":"token_revoked","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 16:00:31.363153+00', ''),
	('00000000-0000-0000-0000-000000000000', '646cc996-1146-4ccc-b5c5-916ba8067730', '{"action":"user_signedup","actor_id":"6a5e67bb-c9b1-4b30-b860-3e4db36fcf2f","actor_name":"Mălina Adriana Lazăr","actor_username":"psiholog.malinalazar@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-15 16:04:01.089107+00', ''),
	('00000000-0000-0000-0000-000000000000', '2c86cd04-9dbb-4771-85cb-d38838a63c05', '{"action":"user_signedup","actor_id":"a7e4662b-0ae7-4687-98f5-a35387a707be","actor_name":"Angelica Iozsi","actor_username":"iozsiangelica@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-15 16:42:14.563958+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd4fa2bb3-9aec-4d54-9f9f-5fe1c804f928', '{"action":"token_refreshed","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 16:59:11.927722+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dc3a7a7e-90e4-4ae8-b055-01eeb6af6529', '{"action":"token_revoked","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 16:59:11.931373+00', ''),
	('00000000-0000-0000-0000-000000000000', '626c4098-dff2-488f-9e8f-f6f76b4ff5e1', '{"action":"logout","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-15 16:59:13.071814+00', ''),
	('00000000-0000-0000-0000-000000000000', '7e82958c-e94a-4af1-b95a-e9f4fd07c9a1', '{"action":"user_confirmation_requested","actor_id":"d0c25236-c4c4-4621-90a1-51f5f4d22d2b","actor_username":"carmen.talan@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-15 17:55:54.476478+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e19b77a0-c018-45cd-a117-6b1f34e66763', '{"action":"user_signedup","actor_id":"d0c25236-c4c4-4621-90a1-51f5f4d22d2b","actor_username":"carmen.talan@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-15 17:56:19.993567+00', ''),
	('00000000-0000-0000-0000-000000000000', 'da398bb3-7af6-4ed2-bab6-2f25be42eb73', '{"action":"token_refreshed","actor_id":"6a5e67bb-c9b1-4b30-b860-3e4db36fcf2f","actor_name":"Mălina Adriana Lazăr","actor_username":"psiholog.malinalazar@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 18:01:05.977979+00', ''),
	('00000000-0000-0000-0000-000000000000', 'eea2a0cf-7088-45fc-b7fc-9026dbfe482d', '{"action":"token_revoked","actor_id":"6a5e67bb-c9b1-4b30-b860-3e4db36fcf2f","actor_name":"Mălina Adriana Lazăr","actor_username":"psiholog.malinalazar@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 18:01:05.979511+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b5ca1aa8-ba18-4dd4-84d9-c0360e80f6f9', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-15 18:40:05.715305+00', ''),
	('00000000-0000-0000-0000-000000000000', '68f67e83-ac87-437a-b185-ab680dd7f642', '{"action":"token_refreshed","actor_id":"f9a83a83-6324-46d1-9e75-3eddf8edd890","actor_username":"anghelescucodrutvictor@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 19:07:24.386055+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e672c096-dbc6-4d3d-b22c-1a45527c7582', '{"action":"token_revoked","actor_id":"f9a83a83-6324-46d1-9e75-3eddf8edd890","actor_username":"anghelescucodrutvictor@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 19:07:24.389768+00', ''),
	('00000000-0000-0000-0000-000000000000', '34f31512-a5a2-4d39-8a07-62bad8f9ae0f', '{"action":"token_refreshed","actor_id":"c07e8742-9b26-4257-80d8-81ea920e3722","actor_name":"Cristina Buzea","actor_username":"cbuzea30@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 19:27:25.958218+00', ''),
	('00000000-0000-0000-0000-000000000000', '1896f43f-2190-4fd3-8a1a-1d5b1c1d42c1', '{"action":"token_revoked","actor_id":"c07e8742-9b26-4257-80d8-81ea920e3722","actor_name":"Cristina Buzea","actor_username":"cbuzea30@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 19:27:25.960714+00', ''),
	('00000000-0000-0000-0000-000000000000', '3a524068-d18e-4833-a7a6-876993653c65', '{"action":"token_refreshed","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 20:23:02.557334+00', ''),
	('00000000-0000-0000-0000-000000000000', '89c0f2f1-362e-4aa7-9bf2-98f1210a8d85', '{"action":"token_revoked","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-15 20:23:02.558974+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c8002eb1-8f86-4123-8f17-8a5bc21a0d7e', '{"action":"token_refreshed","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 01:27:43.223702+00', ''),
	('00000000-0000-0000-0000-000000000000', '25272bf0-4181-4f20-b4b5-3a52f17f4fdc', '{"action":"token_revoked","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 01:27:43.227809+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cf18809a-3b5b-4bcb-869e-f60d2602fefd', '{"action":"logout","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-16 02:04:43.37587+00', ''),
	('00000000-0000-0000-0000-000000000000', '220c5b67-59b2-4b98-91f3-9e89f6c7413e', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-16 02:05:12.701042+00', ''),
	('00000000-0000-0000-0000-000000000000', '86f50f7c-92d8-4cb7-a62f-02d977d5138b', '{"action":"token_refreshed","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 05:03:41.411365+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f38b9653-0df6-41f3-aa7c-44e71760e7cb', '{"action":"token_revoked","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 05:03:41.421849+00', ''),
	('00000000-0000-0000-0000-000000000000', '1f445f3f-6131-406b-a3d0-fe1cd368f152', '{"action":"logout","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-16 05:13:04.187604+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c88dcb45-e5aa-47de-bb23-61fea35619a9', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 05:15:46.913417+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ae49117c-e068-4c89-a99d-d787823edda0', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 05:15:46.914458+00', ''),
	('00000000-0000-0000-0000-000000000000', 'de545a00-903d-4aec-b04c-fab7a1c3d6ee', '{"action":"token_refreshed","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 05:55:54.926369+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd538e619-3a8e-47f7-81f9-551e95681440', '{"action":"token_revoked","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 05:55:54.930135+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ec67c02d-ddee-4e35-9a48-14b31c1f6582', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-16 07:50:02.156863+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c5c3370c-ff63-416d-afac-50432f99a7bc', '{"action":"logout","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-16 08:06:57.108921+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd115053d-fb15-4952-adf4-d40bc480d48f', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-16 08:07:38.437567+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b456cdc9-a3e0-49aa-bd05-cdc7e0fe0b1a', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-16 08:16:56.195864+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c9e95b05-d2a9-4410-b1b8-0382f2aab823', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-16 08:19:18.555649+00', ''),
	('00000000-0000-0000-0000-000000000000', '28ffd877-49b8-468e-9adf-c1bf641c6937', '{"action":"logout","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-16 08:21:28.1931+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd446710e-33d8-4aee-8d48-6ccccc501d0e', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-16 08:22:03.274124+00', ''),
	('00000000-0000-0000-0000-000000000000', '70cd73be-d151-475d-b920-01218a60da06', '{"action":"logout","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-16 08:22:15.116037+00', ''),
	('00000000-0000-0000-0000-000000000000', '7d26603a-be98-4c11-a9a2-40d094fb0d49', '{"action":"user_confirmation_requested","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-16 08:24:19.314559+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dba25e7a-5a0f-4d84-a071-70cc06d7835a', '{"action":"user_signedup","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-16 08:24:36.213804+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c6b42f94-12c5-4e6f-a093-79c5ba0579f6', '{"action":"login","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-16 08:24:56.559323+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f3694efb-0a8e-4217-a4d2-db0570f4695c', '{"action":"login","actor_id":"d0c25236-c4c4-4621-90a1-51f5f4d22d2b","actor_username":"carmen.talan@yahoo.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-16 08:53:19.92727+00', ''),
	('00000000-0000-0000-0000-000000000000', '4813c470-281d-4528-96d5-3f6343d285bb', '{"action":"token_refreshed","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 09:10:47.931681+00', ''),
	('00000000-0000-0000-0000-000000000000', '17b0aa73-67ea-4de9-afb2-7e94ce06817e', '{"action":"token_revoked","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 09:10:47.932578+00', ''),
	('00000000-0000-0000-0000-000000000000', '117866da-5679-4621-a52b-15ff4d32ef99', '{"action":"user_signedup","actor_id":"512c3b3b-0fa0-4659-8c0e-daccd911baa6","actor_name":"Cătălina Petruș-Pop","actor_username":"petruspop.catalina@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-16 09:10:55.516803+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e866fd71-c1e9-49bb-8bc4-5af4739f4bd1', '{"action":"user_confirmation_requested","actor_id":"3bbd94c4-f929-4d5a-9621-721d396f75e3","actor_username":"psih.alinafr@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-16 09:27:39.802159+00', ''),
	('00000000-0000-0000-0000-000000000000', '58efbfd1-c386-45ff-8118-6b60f08e779b', '{"action":"user_signedup","actor_id":"3bbd94c4-f929-4d5a-9621-721d396f75e3","actor_username":"psih.alinafr@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-16 09:28:24.840846+00', ''),
	('00000000-0000-0000-0000-000000000000', '1731409e-3c1f-4375-8dec-925552a7f97c', '{"action":"user_confirmation_requested","actor_id":"c7fc72ce-3614-4d3a-a617-c7b5aa2d9cd0","actor_username":"ageorgescu22@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-16 09:42:57.9602+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dbfaf10f-dad4-4bd4-a352-88ed63aca202', '{"action":"token_refreshed","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 09:44:49.659476+00', ''),
	('00000000-0000-0000-0000-000000000000', '9feedea2-3ff9-4d52-8176-f70bc1d4f700', '{"action":"token_revoked","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 09:44:49.660979+00', ''),
	('00000000-0000-0000-0000-000000000000', '2344aaa8-5d87-4fa2-94db-f67cf5b7dc60', '{"action":"token_refreshed","actor_id":"d0c25236-c4c4-4621-90a1-51f5f4d22d2b","actor_username":"carmen.talan@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 09:51:43.136307+00', ''),
	('00000000-0000-0000-0000-000000000000', '38fe5964-b315-4273-8f6c-fc12fc703725', '{"action":"token_revoked","actor_id":"d0c25236-c4c4-4621-90a1-51f5f4d22d2b","actor_username":"carmen.talan@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 09:51:43.139392+00', ''),
	('00000000-0000-0000-0000-000000000000', '7edae54e-745e-4f54-81ca-b14bd497e4a1', '{"action":"login","actor_id":"d0c25236-c4c4-4621-90a1-51f5f4d22d2b","actor_username":"carmen.talan@yahoo.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-16 09:56:30.818033+00', ''),
	('00000000-0000-0000-0000-000000000000', '127fa9ee-e52b-42b7-b4a7-8a4d790f795a', '{"action":"user_signedup","actor_id":"3e6b8532-e559-4bba-a913-9178fdb2a0bd","actor_name":"Sorina Brif","actor_username":"brifsorina@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-16 10:42:46.605555+00', ''),
	('00000000-0000-0000-0000-000000000000', '957bdbc6-781b-42a8-ad19-2327f94dd3ca', '{"action":"user_confirmation_requested","actor_id":"d1792c86-294f-453e-ae1e-8474ab5553e3","actor_username":"mihaelastanciu999@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-16 10:42:59.922163+00', ''),
	('00000000-0000-0000-0000-000000000000', '72272e12-cdae-44b2-a62b-1f14eff10e1c', '{"action":"user_signedup","actor_id":"d1792c86-294f-453e-ae1e-8474ab5553e3","actor_username":"mihaelastanciu999@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-16 10:43:17.044217+00', ''),
	('00000000-0000-0000-0000-000000000000', '9a2781cc-3e80-4e78-a1f3-0e80753ad2d6', '{"action":"user_confirmation_requested","actor_id":"52514d39-b9bc-42e3-8a24-69cd971a8414","actor_username":"carmenrauta68@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-16 11:02:28.965399+00', ''),
	('00000000-0000-0000-0000-000000000000', '5147ffcb-d9bd-4d86-b964-813ba8962dae', '{"action":"login","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-16 11:48:33.438768+00', ''),
	('00000000-0000-0000-0000-000000000000', '112db753-91f0-44b5-b609-c05f668e3348', '{"action":"logout","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-16 11:50:30.572555+00', ''),
	('00000000-0000-0000-0000-000000000000', '1000c8ee-7db3-4277-91e3-947f4860d8f2', '{"action":"login","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-16 11:59:25.568252+00', ''),
	('00000000-0000-0000-0000-000000000000', 'bb626787-49e0-4c7e-a1b0-612217a92d54', '{"action":"token_refreshed","actor_id":"1d4e4d74-493a-4758-a5e1-3229a81bae5d","actor_username":"inna.medeea.lupu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 12:24:06.627727+00', ''),
	('00000000-0000-0000-0000-000000000000', '90117a04-81f0-43f4-9ec7-960325401a9b', '{"action":"token_revoked","actor_id":"1d4e4d74-493a-4758-a5e1-3229a81bae5d","actor_username":"inna.medeea.lupu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 12:24:06.630448+00', ''),
	('00000000-0000-0000-0000-000000000000', 'bd58b375-5895-4afc-9efc-08a1d52f06ad', '{"action":"user_confirmation_requested","actor_id":"13640682-e72c-448d-87a7-af45f1070498","actor_username":"vali_robu@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-16 12:24:25.744174+00', ''),
	('00000000-0000-0000-0000-000000000000', '6b965079-9e31-45e9-88fb-7aa596bd5fa3', '{"action":"token_refreshed","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 12:25:12.731668+00', ''),
	('00000000-0000-0000-0000-000000000000', '0edf70af-a98c-4f97-9575-4f68d50011ed', '{"action":"token_revoked","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 12:25:12.733643+00', ''),
	('00000000-0000-0000-0000-000000000000', '1260a4f6-bacc-4170-ab39-09812139cac4', '{"action":"user_signedup","actor_id":"13640682-e72c-448d-87a7-af45f1070498","actor_username":"vali_robu@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-16 12:30:27.45335+00', ''),
	('00000000-0000-0000-0000-000000000000', '8ebc4591-55bb-4e8d-920b-4049df84b2c3', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 13:05:40.065458+00', ''),
	('00000000-0000-0000-0000-000000000000', '20133ba8-cadd-4658-9ecb-ff13b0bee671', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 13:05:40.067952+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f770513b-4175-496e-b30f-e4d3308fda05', '{"action":"token_refreshed","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 13:26:57.852284+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ede7e9ee-e206-4b12-8517-79d695e49103', '{"action":"token_revoked","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 13:26:57.855136+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c2986e35-fb1a-4627-8339-7263ee17a7ff', '{"action":"user_confirmation_requested","actor_id":"d707eee8-8de6-49fa-a4a6-00d79d6eded8","actor_username":"camelya98@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-16 14:05:20.122116+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b1cc37ba-0849-4acf-8902-069cdd450610', '{"action":"user_signedup","actor_id":"d707eee8-8de6-49fa-a4a6-00d79d6eded8","actor_username":"camelya98@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-16 14:06:31.829626+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd6d3fdb3-d2eb-4d17-8c75-6a92971048aa', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-16 14:18:07.726153+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c976e491-bb6c-4550-81f0-910269e7a865', '{"action":"logout","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-16 14:18:20.94422+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd9751a22-2682-4019-9fce-e5b638c0271b', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-16 14:18:26.901063+00', ''),
	('00000000-0000-0000-0000-000000000000', '857b5624-0f0e-4d6d-965a-ce0f6ce6c392', '{"action":"token_refreshed","actor_id":"8aa1791f-a04d-4076-8d1d-0f69e1065f34","actor_name":"Baciu Raul","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 14:58:22.689165+00', ''),
	('00000000-0000-0000-0000-000000000000', '3ce90ce5-2c31-4772-9a50-957f7a027b36', '{"action":"token_revoked","actor_id":"8aa1791f-a04d-4076-8d1d-0f69e1065f34","actor_name":"Baciu Raul","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 14:58:22.696544+00', ''),
	('00000000-0000-0000-0000-000000000000', '2358a6c4-d301-4000-affe-0dc704820eef', '{"action":"logout","actor_id":"8aa1791f-a04d-4076-8d1d-0f69e1065f34","actor_name":"Baciu Raul","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-16 14:59:28.264846+00', ''),
	('00000000-0000-0000-0000-000000000000', '7b98e83e-a6bf-4b47-9156-d753e0a68b3b', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-16 14:59:44.553047+00', ''),
	('00000000-0000-0000-0000-000000000000', '38cdfbb9-4099-4712-88e0-cd789fb3c4db', '{"action":"token_refreshed","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 15:00:41.923109+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a1bd5b0b-7f5b-4bad-bbc5-71eab1d91f2d', '{"action":"token_revoked","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 15:00:41.923666+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b98efd7d-c914-4936-b0bd-fe09fa0f8f98', '{"action":"token_refreshed","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 15:13:24.059675+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f5fdfb3f-092c-4313-9a3e-177586499a2b', '{"action":"token_revoked","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 15:13:24.063667+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd24aff9d-a1f3-468f-88fe-76cc498e41fa', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 15:22:10.02742+00', ''),
	('00000000-0000-0000-0000-000000000000', '9f79f964-88c4-47a3-8da4-84fbaa0ecc3e', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 15:22:10.032151+00', ''),
	('00000000-0000-0000-0000-000000000000', '1a6ddd2e-bb53-461a-b7c5-fced96eeacde', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 16:04:42.354178+00', ''),
	('00000000-0000-0000-0000-000000000000', '3e7f339a-89e2-414d-bbf6-03203032ca45', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 16:04:42.356772+00', ''),
	('00000000-0000-0000-0000-000000000000', '3ecfd278-71b8-4b18-957e-dcaa9c7974a9', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-16 16:04:56.198801+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c765ef9e-a467-421e-8106-c0b4c17b4508', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-16 16:05:01.754196+00', ''),
	('00000000-0000-0000-0000-000000000000', '5d8f42df-8162-46b9-8046-1948f7ebebdf', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 17:03:36.091911+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cc269d85-e90d-43c8-a92f-dbd526b6f380', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 17:03:36.095288+00', ''),
	('00000000-0000-0000-0000-000000000000', '6a6f958e-d15e-4243-848e-812e7dfadbdc', '{"action":"login","actor_id":"13640682-e72c-448d-87a7-af45f1070498","actor_username":"vali_robu@yahoo.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-16 18:28:24.970795+00', ''),
	('00000000-0000-0000-0000-000000000000', '5bd7b41b-e4da-4741-b12b-8e60e8b920c4', '{"action":"token_refreshed","actor_id":"f9a83a83-6324-46d1-9e75-3eddf8edd890","actor_username":"anghelescucodrutvictor@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 19:31:43.220792+00', ''),
	('00000000-0000-0000-0000-000000000000', '160d2a6e-1015-47bc-a255-421f7a390a5d', '{"action":"token_revoked","actor_id":"f9a83a83-6324-46d1-9e75-3eddf8edd890","actor_username":"anghelescucodrutvictor@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 19:31:43.228573+00', ''),
	('00000000-0000-0000-0000-000000000000', '35dda9f3-482d-436b-be0c-542fe42af36a', '{"action":"login","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-16 19:43:13.589525+00', ''),
	('00000000-0000-0000-0000-000000000000', '157ce786-d799-445d-9002-d2d666ddbfa9', '{"action":"token_refreshed","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 20:13:55.270569+00', ''),
	('00000000-0000-0000-0000-000000000000', '3e0abf9f-020f-4102-a9a5-417dbb19cd42', '{"action":"token_revoked","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-16 20:13:55.272191+00', ''),
	('00000000-0000-0000-0000-000000000000', '29808bca-f472-4af3-abc7-a943c5e67d03', '{"action":"token_refreshed","actor_id":"13640682-e72c-448d-87a7-af45f1070498","actor_username":"vali_robu@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 02:06:46.847102+00', ''),
	('00000000-0000-0000-0000-000000000000', '36ffbbf3-ce3e-4e57-ad82-bf30a9d56f7a', '{"action":"token_revoked","actor_id":"13640682-e72c-448d-87a7-af45f1070498","actor_username":"vali_robu@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 02:06:46.851332+00', ''),
	('00000000-0000-0000-0000-000000000000', '1ea0c0c8-9289-4580-a9e5-a80f3c218179', '{"action":"user_confirmation_requested","actor_id":"7617e0bf-ca39-47d8-a708-935afb8eaf87","actor_username":"laura_stan80@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-17 05:29:41.068966+00', ''),
	('00000000-0000-0000-0000-000000000000', '269202b1-6859-48b1-94bb-42e981b0d275', '{"action":"user_signedup","actor_id":"7617e0bf-ca39-47d8-a708-935afb8eaf87","actor_username":"laura_stan80@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-17 05:30:31.768919+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c62ce30b-f7dc-4106-9dcd-9a5e5a325481', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-17 06:28:23.659831+00', ''),
	('00000000-0000-0000-0000-000000000000', '5dface05-730e-42a2-949c-da4a3227247d', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 06:55:38.136775+00', ''),
	('00000000-0000-0000-0000-000000000000', '1b16e088-a273-4e19-ab2c-a4e459e9cc72', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 06:55:38.139545+00', ''),
	('00000000-0000-0000-0000-000000000000', '8af90303-fdb4-48a1-8880-3fc6d320e0c0', '{"action":"login","actor_id":"d707eee8-8de6-49fa-a4a6-00d79d6eded8","actor_username":"camelya98@yahoo.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-17 07:08:52.911327+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c9dad193-4d1e-4efd-a0e5-aa3c4cf3d90b', '{"action":"token_refreshed","actor_id":"f9a83a83-6324-46d1-9e75-3eddf8edd890","actor_username":"anghelescucodrutvictor@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 07:10:28.102448+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f73896d0-6ed9-4641-ad2e-9324dd6bd6e5', '{"action":"token_revoked","actor_id":"f9a83a83-6324-46d1-9e75-3eddf8edd890","actor_username":"anghelescucodrutvictor@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 07:10:28.104817+00', ''),
	('00000000-0000-0000-0000-000000000000', '3df41262-dd58-4ce9-8232-45bb105d6d60', '{"action":"token_refreshed","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 07:12:43.766131+00', ''),
	('00000000-0000-0000-0000-000000000000', '46fc80e0-a1c4-4435-b40e-0e6819f21029', '{"action":"token_revoked","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 07:12:43.768416+00', ''),
	('00000000-0000-0000-0000-000000000000', '0ff5a633-a3e7-4ba6-9f3e-5b6d25bada6a', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-17 07:17:12.026702+00', ''),
	('00000000-0000-0000-0000-000000000000', '34434b83-50db-4a10-bf52-14d31e1bc5d6', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-17 07:17:55.619293+00', ''),
	('00000000-0000-0000-0000-000000000000', '44521b2c-31cd-41b8-adf6-2d297a764e6e', '{"action":"logout","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-17 07:18:30.655732+00', ''),
	('00000000-0000-0000-0000-000000000000', '12ebf3bf-16d3-419f-9308-ae668715ff6d', '{"action":"user_repeated_signup","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-17 07:18:42.683036+00', ''),
	('00000000-0000-0000-0000-000000000000', '3b439cf4-a1cb-42c2-8a51-baa534c343d4', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-17 07:19:01.252641+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c470f251-7ef8-4dbe-ae05-b45cdc552617', '{"action":"token_refreshed","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 07:33:15.289672+00', ''),
	('00000000-0000-0000-0000-000000000000', '0985fcc1-1cf9-4656-b5ad-8fc035f14dcb', '{"action":"token_revoked","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 07:33:15.292952+00', ''),
	('00000000-0000-0000-0000-000000000000', '72debf28-c578-4a31-97b9-83499b95d956', '{"action":"token_refreshed","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 08:20:26.097379+00', ''),
	('00000000-0000-0000-0000-000000000000', '6aea0da5-3e68-4252-82c9-202bb205dd9b', '{"action":"token_revoked","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 08:20:26.102739+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd5572fcd-79dc-486e-820c-73e192000104', '{"action":"token_refreshed","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 08:30:22.829886+00', ''),
	('00000000-0000-0000-0000-000000000000', 'acebaf41-224d-402a-afe2-af47ddabd61b', '{"action":"token_revoked","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 08:30:22.832673+00', ''),
	('00000000-0000-0000-0000-000000000000', '3371d759-cd87-466f-a3dc-f4a06624541c', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-17 08:30:51.542356+00', ''),
	('00000000-0000-0000-0000-000000000000', '16cf5cdd-4eed-47b1-b8a8-96a8f72b3d76', '{"action":"token_refreshed","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 08:36:44.872339+00', ''),
	('00000000-0000-0000-0000-000000000000', 'db083484-272f-4272-aaef-fadbfdf9e6b3', '{"action":"token_revoked","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 08:36:44.875736+00', ''),
	('00000000-0000-0000-0000-000000000000', '735f6e3b-5556-4735-aafd-f7b53b4f47f8', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-17 08:48:54.064097+00', ''),
	('00000000-0000-0000-0000-000000000000', '3fcc0db1-5a6b-458c-9fe5-1923f44a7ed0', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-17 08:58:41.674987+00', ''),
	('00000000-0000-0000-0000-000000000000', 'aa68b71b-def1-4f5d-a798-8923871dfb2f', '{"action":"logout","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-17 09:20:27.741551+00', ''),
	('00000000-0000-0000-0000-000000000000', '6216b64f-ec5c-4776-86bd-b823ca9ebede', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-17 09:20:36.5449+00', ''),
	('00000000-0000-0000-0000-000000000000', '8b05aeb3-1a0a-491c-95d6-d4d8bedd434d', '{"action":"logout","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-17 09:58:32.724002+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e2c40535-ec70-4118-a41b-beaa4e115a78', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-17 09:58:54.170696+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f91e766c-4368-473c-810a-6985a7cb4e6f', '{"action":"token_refreshed","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 10:13:41.923673+00', ''),
	('00000000-0000-0000-0000-000000000000', '9de8fa25-a8ca-4e2f-b8fe-234644b3fbec', '{"action":"token_revoked","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 10:13:41.926216+00', ''),
	('00000000-0000-0000-0000-000000000000', 'db324dd2-2400-46a9-8ee6-dc4635a4c3e0', '{"action":"token_refreshed","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 10:38:56.57521+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd1422c98-9d50-47ce-9b9c-d4d21bebf136', '{"action":"token_revoked","actor_id":"0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca","actor_name":"Denisa Romanică","actor_username":"romanica.denisa@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 10:38:56.578402+00', ''),
	('00000000-0000-0000-0000-000000000000', '09de7cf2-c33b-4d18-86c0-8f13fc8b7777', '{"action":"token_refreshed","actor_id":"13640682-e72c-448d-87a7-af45f1070498","actor_username":"vali_robu@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 17:47:28.730073+00', ''),
	('00000000-0000-0000-0000-000000000000', '8b4a10c3-b663-4d3f-bec0-8e4067331887', '{"action":"token_revoked","actor_id":"13640682-e72c-448d-87a7-af45f1070498","actor_username":"vali_robu@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 17:47:28.749694+00', ''),
	('00000000-0000-0000-0000-000000000000', '157e8af4-f298-4aee-98b3-d1952ce831d3', '{"action":"token_refreshed","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 18:12:26.651565+00', ''),
	('00000000-0000-0000-0000-000000000000', '45cd9e95-f352-42f4-bf2b-2addc6c137bd', '{"action":"token_revoked","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 18:12:26.65317+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ba66fff5-72f5-4a44-a733-991da36d6fee', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-17 18:32:36.939914+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b849148a-0dab-40fb-a358-76ac5505245b', '{"action":"token_refreshed","actor_id":"13640682-e72c-448d-87a7-af45f1070498","actor_username":"vali_robu@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 19:08:57.73225+00', ''),
	('00000000-0000-0000-0000-000000000000', '3eb1383f-e53c-4b55-b139-e474b908392c', '{"action":"token_revoked","actor_id":"13640682-e72c-448d-87a7-af45f1070498","actor_username":"vali_robu@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 19:08:57.734842+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dfe4a3ce-23b0-46eb-9165-fc4004e6d162', '{"action":"token_refreshed","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 19:11:29.593856+00', ''),
	('00000000-0000-0000-0000-000000000000', '967e71e1-984a-42a1-9917-d3cc660bfbc6', '{"action":"token_revoked","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 19:11:29.597623+00', ''),
	('00000000-0000-0000-0000-000000000000', '260ed004-222f-42b9-9725-d7a62471713c', '{"action":"logout","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-17 19:11:32.251947+00', ''),
	('00000000-0000-0000-0000-000000000000', '1a934bb8-3ebd-4e3c-897a-eefa19b76f88', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-17 19:12:02.105023+00', ''),
	('00000000-0000-0000-0000-000000000000', '4e18fe49-c25c-47d7-8546-73b20ff6aeff', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 20:07:46.537349+00', ''),
	('00000000-0000-0000-0000-000000000000', '4a557284-c3d3-4a40-b227-7534e4218cf3', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-17 20:07:46.538946+00', ''),
	('00000000-0000-0000-0000-000000000000', '368b6090-dc63-4b66-8c07-4d2986eb1445', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 01:24:26.695437+00', ''),
	('00000000-0000-0000-0000-000000000000', '342bd405-c922-467d-a79b-d20694b82eb7', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 01:24:26.699171+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ecf35bf8-f738-4628-a101-dbff9cb66d8e', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 06:11:23.867621+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c365d670-d9cb-4c50-b3d4-dc7f77d60ede', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 06:11:23.875776+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ec6f6fb7-d8c8-494c-b77f-b22e56edfdc1', '{"action":"token_refreshed","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 09:29:43.840287+00', ''),
	('00000000-0000-0000-0000-000000000000', '9fa4af18-e6c8-4b08-80b8-d127dde94133', '{"action":"token_revoked","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 09:29:43.852576+00', ''),
	('00000000-0000-0000-0000-000000000000', '1fc06e0d-c896-4415-927c-3696b809d1af', '{"action":"token_refreshed","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 09:33:13.625827+00', ''),
	('00000000-0000-0000-0000-000000000000', '7f5ef741-aaf8-4bf2-8fed-85f9c5f6604f', '{"action":"token_revoked","actor_id":"49af0fde-1e09-4899-85d0-42f87dc62ad7","actor_username":"mihocbogdan96@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 09:33:13.635371+00', ''),
	('00000000-0000-0000-0000-000000000000', '481b26b6-4783-44c0-ad05-4617fc00dc8f', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 10:11:40.7704+00', ''),
	('00000000-0000-0000-0000-000000000000', '9a00b2d7-cb6c-4a48-afd9-1ac42e4a792e', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 10:11:40.775289+00', ''),
	('00000000-0000-0000-0000-000000000000', '0660dc61-4666-4f51-a86d-9961f93f072a', '{"action":"token_refreshed","actor_id":"c07e8742-9b26-4257-80d8-81ea920e3722","actor_name":"Cristina Buzea","actor_username":"cbuzea30@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 10:23:12.300204+00', ''),
	('00000000-0000-0000-0000-000000000000', '55863e57-6829-45e0-a94a-915fd97b7cb4', '{"action":"token_revoked","actor_id":"c07e8742-9b26-4257-80d8-81ea920e3722","actor_name":"Cristina Buzea","actor_username":"cbuzea30@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 10:23:12.304097+00', ''),
	('00000000-0000-0000-0000-000000000000', '6ea90f8d-cb8f-4e44-90d6-e706d53f5c22', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-18 10:44:13.028863+00', ''),
	('00000000-0000-0000-0000-000000000000', '719ef059-8eeb-4417-9ed0-9965fead7068', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-18 10:44:15.219266+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b1df5e82-d38a-489c-bd5f-07a1c6094867', '{"action":"token_refreshed","actor_id":"8e441edf-2d91-4551-a4e6-924316cd2090","actor_username":"contactandreigeorge@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 11:19:55.98223+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e66446a7-28c5-4de7-8dac-0b6bb347b779', '{"action":"token_revoked","actor_id":"8e441edf-2d91-4551-a4e6-924316cd2090","actor_username":"contactandreigeorge@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 11:19:55.988784+00', ''),
	('00000000-0000-0000-0000-000000000000', '480d24cb-2d66-478b-8f82-a3a40690ca23', '{"action":"token_refreshed","actor_id":"c07e8742-9b26-4257-80d8-81ea920e3722","actor_name":"Cristina Buzea","actor_username":"cbuzea30@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 11:45:59.727747+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fdd059f9-a60c-405b-b606-e84fabee971a', '{"action":"token_revoked","actor_id":"c07e8742-9b26-4257-80d8-81ea920e3722","actor_name":"Cristina Buzea","actor_username":"cbuzea30@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 11:45:59.730579+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f9059b9d-129d-4030-b7cd-cd203a1e061e', '{"action":"token_refreshed","actor_id":"8e441edf-2d91-4551-a4e6-924316cd2090","actor_username":"contactandreigeorge@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 12:19:42.417351+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b6e2dc25-57d8-4341-9d32-a723de949af6', '{"action":"token_revoked","actor_id":"8e441edf-2d91-4551-a4e6-924316cd2090","actor_username":"contactandreigeorge@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 12:19:42.419929+00', ''),
	('00000000-0000-0000-0000-000000000000', '99d1c554-02a4-4c0f-b6a2-a36f993e913f', '{"action":"token_refreshed","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 12:59:10.319702+00', ''),
	('00000000-0000-0000-0000-000000000000', '2d0865f2-8f3f-41ed-9c96-3f7b7e7d0ec3', '{"action":"token_revoked","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 12:59:10.322537+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c4535529-58a6-4380-a77f-ce951986cd99', '{"action":"user_signedup","actor_id":"459220a9-338b-4a45-8533-24789a3b1da7","actor_name":"Miu Simplu","actor_username":"miusimplu@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-18 13:24:52.969599+00', ''),
	('00000000-0000-0000-0000-000000000000', '1c34ef2d-ae3d-4286-8cd1-c513062255b5', '{"action":"token_refreshed","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 15:10:27.222516+00', ''),
	('00000000-0000-0000-0000-000000000000', '895a9cfb-41bf-4927-a6ac-3da3924b4768', '{"action":"token_revoked","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 15:10:27.225791+00', ''),
	('00000000-0000-0000-0000-000000000000', '16f3a9a2-a91e-4e89-b772-ed6acb5d38ad', '{"action":"logout","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-18 15:10:32.912586+00', ''),
	('00000000-0000-0000-0000-000000000000', '39f99070-15ab-4082-84d2-4574c355b122', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 15:32:23.071109+00', ''),
	('00000000-0000-0000-0000-000000000000', '46db2e5d-77c0-486e-b85b-11bae9863cd8', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 15:32:23.075614+00', ''),
	('00000000-0000-0000-0000-000000000000', '06597f7a-df8c-4bb6-8015-adb937e68bd1', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 16:52:47.805299+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a0d212ef-d283-4dcb-84ac-809a19f0cf37', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-18 16:52:47.807621+00', ''),
	('00000000-0000-0000-0000-000000000000', '121bfafe-f94b-4b37-ad94-dbb2e74a5f77', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-18 16:52:55.304358+00', ''),
	('00000000-0000-0000-0000-000000000000', '9a532f19-bb18-4753-803b-2532b2f01d49', '{"action":"login","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-18 16:53:16.927109+00', ''),
	('00000000-0000-0000-0000-000000000000', '217cb96a-bf3b-4dcf-aeb7-a27479ef65a5', '{"action":"token_refreshed","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 01:48:21.654397+00', ''),
	('00000000-0000-0000-0000-000000000000', '44022483-d683-4025-b51a-41c6c0a4adee', '{"action":"token_revoked","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 01:48:21.661697+00', ''),
	('00000000-0000-0000-0000-000000000000', '2933d257-4e2d-48a9-97ae-4c67f905d1f8', '{"action":"logout","actor_id":"cf18dae6-9d04-4fa7-b284-f4ef1164a1ef","actor_username":"gorjy.ghy@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-19 01:48:27.011153+00', ''),
	('00000000-0000-0000-0000-000000000000', '03abf9d9-6be3-469e-be6d-c4e8bcb53c18', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-19 01:48:31.178143+00', ''),
	('00000000-0000-0000-0000-000000000000', '104e0090-e20c-4d91-939f-c5eba20ccebc', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 02:55:42.561402+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dcdb5eb2-0c89-4112-b8b3-2fd64fe0a1d0', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 02:55:42.565362+00', ''),
	('00000000-0000-0000-0000-000000000000', '9d993ef2-f2a2-419f-a97b-d32c0804ad9b', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 03:55:48.350539+00', ''),
	('00000000-0000-0000-0000-000000000000', '799338f1-1cb4-4535-82c5-c06eb395f247', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 03:55:48.359278+00', ''),
	('00000000-0000-0000-0000-000000000000', '0d01a31d-83b2-4d59-9023-9ae1aa4403dd', '{"action":"login","actor_id":"7617e0bf-ca39-47d8-a708-935afb8eaf87","actor_username":"laura_stan80@yahoo.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-19 05:01:04.935435+00', ''),
	('00000000-0000-0000-0000-000000000000', 'bf045c8c-ec25-4b39-a779-55082fdd8d23', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 05:08:19.745271+00', ''),
	('00000000-0000-0000-0000-000000000000', '9a4c0bd5-f4b9-4519-b055-00d75e161f7f', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 05:08:19.749581+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd46ae443-1575-4541-b962-341c4c3dade3', '{"action":"login","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-19 05:29:56.201834+00', ''),
	('00000000-0000-0000-0000-000000000000', '3ec14cae-ba1f-462b-9da4-91da95f86de5', '{"action":"user_confirmation_requested","actor_id":"9945cd00-d2ba-494d-9852-4d9ceb75258e","actor_username":"lilea.emanuelacristina@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 05:57:40.619644+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd690d349-d5b5-4fae-bb56-2a59fc378cf4', '{"action":"user_signedup","actor_id":"9945cd00-d2ba-494d-9852-4d9ceb75258e","actor_username":"lilea.emanuelacristina@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-19 05:57:49.926314+00', ''),
	('00000000-0000-0000-0000-000000000000', '73ac6362-fd65-44fa-b49a-b684123dfb37', '{"action":"user_confirmation_requested","actor_id":"23584fae-eae0-4163-9e12-0e8fc3d4047e","actor_username":"geaninabasturescu@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 06:00:38.294959+00', ''),
	('00000000-0000-0000-0000-000000000000', '57eae82e-69fc-450f-ad1c-83aaccde430e', '{"action":"user_signedup","actor_id":"23584fae-eae0-4163-9e12-0e8fc3d4047e","actor_username":"geaninabasturescu@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-19 06:01:06.647008+00', ''),
	('00000000-0000-0000-0000-000000000000', '929cb1b3-b7d3-46b7-a857-ad11abd1efd6', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 06:19:42.682917+00', ''),
	('00000000-0000-0000-0000-000000000000', '5c9778cb-b24a-45d9-8b94-04b7b7d302d7', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 06:19:42.68392+00', ''),
	('00000000-0000-0000-0000-000000000000', '09400c1e-d9ab-4ee6-a9eb-e6f584027785', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-19 06:33:11.04448+00', ''),
	('00000000-0000-0000-0000-000000000000', '824a1021-64f0-4ca5-81f3-bbaaed0e71e0', '{"action":"token_refreshed","actor_id":"8e441edf-2d91-4551-a4e6-924316cd2090","actor_username":"contactandreigeorge@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 06:33:55.008377+00', ''),
	('00000000-0000-0000-0000-000000000000', '750e6dab-97f0-4719-8f86-4bc364a05aad', '{"action":"token_revoked","actor_id":"8e441edf-2d91-4551-a4e6-924316cd2090","actor_username":"contactandreigeorge@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 06:33:55.010456+00', ''),
	('00000000-0000-0000-0000-000000000000', '44a766db-eca2-451f-b192-097e712ddc3e', '{"action":"token_refreshed","actor_id":"7617e0bf-ca39-47d8-a708-935afb8eaf87","actor_username":"laura_stan80@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 06:45:01.297082+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd7e7ef84-2d1e-44a6-bfa7-5ef4e4e88d92', '{"action":"token_revoked","actor_id":"7617e0bf-ca39-47d8-a708-935afb8eaf87","actor_username":"laura_stan80@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 06:45:01.299164+00', ''),
	('00000000-0000-0000-0000-000000000000', '692fa79e-7cd1-4213-aa6b-c9cb1a7e9fb9', '{"action":"token_refreshed","actor_id":"8e441edf-2d91-4551-a4e6-924316cd2090","actor_username":"contactandreigeorge@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 07:32:39.730608+00', ''),
	('00000000-0000-0000-0000-000000000000', '3ce7b7ce-e6d3-44a5-8a4a-29f6ceb4f271', '{"action":"token_revoked","actor_id":"8e441edf-2d91-4551-a4e6-924316cd2090","actor_username":"contactandreigeorge@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 07:32:39.734161+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c731081f-2fdb-403d-b21e-2bae8d11faff', '{"action":"user_confirmation_requested","actor_id":"ab84c874-6fed-45be-9e1d-28da0a041149","actor_username":"elenadaniele_popa@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 07:53:38.693312+00', ''),
	('00000000-0000-0000-0000-000000000000', '8762c133-44cc-4831-a76e-b07d6179d396', '{"action":"user_signedup","actor_id":"ab84c874-6fed-45be-9e1d-28da0a041149","actor_username":"elenadaniele_popa@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-19 07:53:58.125188+00', ''),
	('00000000-0000-0000-0000-000000000000', '60887156-6eca-4aa3-a70e-2814bded3707', '{"action":"user_confirmation_requested","actor_id":"c727ce88-386f-49e6-88c9-df7115e793e5","actor_username":"gianinacornea@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 08:07:16.767211+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f8ab23f5-b233-451d-8e59-391b83e44b4c', '{"action":"user_signedup","actor_id":"c727ce88-386f-49e6-88c9-df7115e793e5","actor_username":"gianinacornea@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-19 08:08:05.818241+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ea0c2220-f68d-4cc3-86ae-a9d7fa31582a', '{"action":"user_confirmation_requested","actor_id":"3add3342-f74c-49c7-985b-238208eebac5","actor_username":"terapeutdenisaelena@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 08:56:43.558571+00', ''),
	('00000000-0000-0000-0000-000000000000', '810877e7-36d6-4550-b234-6b7e7055c277', '{"action":"user_signedup","actor_id":"3add3342-f74c-49c7-985b-238208eebac5","actor_username":"terapeutdenisaelena@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-19 08:57:17.584494+00', ''),
	('00000000-0000-0000-0000-000000000000', '062aa2fd-0a7c-4ba1-9f01-899f37371468', '{"action":"login","actor_id":"3add3342-f74c-49c7-985b-238208eebac5","actor_username":"terapeutdenisaelena@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-19 08:57:38.073393+00', ''),
	('00000000-0000-0000-0000-000000000000', 'db6bb2b6-bb2d-499a-8a82-38b466bef6db', '{"action":"token_refreshed","actor_id":"d707eee8-8de6-49fa-a4a6-00d79d6eded8","actor_username":"camelya98@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 09:31:59.33197+00', ''),
	('00000000-0000-0000-0000-000000000000', '3d35d878-d474-4147-affc-0539d57736c6', '{"action":"token_revoked","actor_id":"d707eee8-8de6-49fa-a4a6-00d79d6eded8","actor_username":"camelya98@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 09:31:59.335121+00', ''),
	('00000000-0000-0000-0000-000000000000', '113628fa-569b-4a59-bc65-3479957dcff2', '{"action":"login","actor_id":"d707eee8-8de6-49fa-a4a6-00d79d6eded8","actor_username":"camelya98@yahoo.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-19 09:32:20.434936+00', ''),
	('00000000-0000-0000-0000-000000000000', '66319565-becd-4e74-8635-f200151c85ad', '{"action":"user_confirmation_requested","actor_id":"a6f658f8-149d-4063-b1d9-c54105f03392","actor_username":"nicoldina1974@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 09:41:14.732801+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b078a5e9-fec3-44b5-841d-1e2c1678f1c0', '{"action":"user_signedup","actor_id":"a6f658f8-149d-4063-b1d9-c54105f03392","actor_username":"nicoldina1974@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-19 09:41:32.124658+00', ''),
	('00000000-0000-0000-0000-000000000000', '718033fa-792e-4886-b273-84d7d2b14eb9', '{"action":"user_confirmation_requested","actor_id":"53c97092-2634-4c47-ad83-808566dfbdcd","actor_username":"psiholog.cristina-avram@outlook.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 09:42:38.949496+00', ''),
	('00000000-0000-0000-0000-000000000000', '9ce721dc-48d8-409a-a853-4d8ac15ba78e', '{"action":"user_signedup","actor_id":"53c97092-2634-4c47-ad83-808566dfbdcd","actor_username":"psiholog.cristina-avram@outlook.com","actor_via_sso":false,"log_type":"team"}', '2025-05-19 09:42:54.739058+00', ''),
	('00000000-0000-0000-0000-000000000000', 'aefe9aff-540b-4222-b22e-0fe52262e5cd', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 09:46:14.594719+00', ''),
	('00000000-0000-0000-0000-000000000000', '61c80562-5ccf-44bb-9c7d-05b446229547', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 09:46:14.596822+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e990b085-2e48-4b25-87d6-81043b5af238', '{"action":"token_refreshed","actor_id":"a6f658f8-149d-4063-b1d9-c54105f03392","actor_username":"nicoldina1974@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 10:39:44.090645+00', ''),
	('00000000-0000-0000-0000-000000000000', '0d757125-0232-430e-b451-d309d3fb10cb', '{"action":"token_revoked","actor_id":"a6f658f8-149d-4063-b1d9-c54105f03392","actor_username":"nicoldina1974@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 10:39:44.09356+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c565d9f1-63a3-495f-b679-b50ed6f7815f', '{"action":"token_refreshed","actor_id":"1d4e4d74-493a-4758-a5e1-3229a81bae5d","actor_username":"inna.medeea.lupu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 10:40:54.829405+00', ''),
	('00000000-0000-0000-0000-000000000000', '6e688e2d-324b-44fc-b581-9585e395baf0', '{"action":"token_revoked","actor_id":"1d4e4d74-493a-4758-a5e1-3229a81bae5d","actor_username":"inna.medeea.lupu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 10:40:54.830371+00', ''),
	('00000000-0000-0000-0000-000000000000', '2e4daa93-a71a-4b64-af1d-015d0eb37053', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 11:01:43.420553+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e8348cb7-1829-4701-b66d-05526a9a11a7', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 11:01:43.422676+00', ''),
	('00000000-0000-0000-0000-000000000000', '8c8a7438-36ba-4fca-b6c8-ecb1ce110e37', '{"action":"token_refreshed","actor_id":"d707eee8-8de6-49fa-a4a6-00d79d6eded8","actor_username":"camelya98@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 11:02:26.494748+00', ''),
	('00000000-0000-0000-0000-000000000000', '8d1cba10-5d7c-471c-bcc1-45077cf75c43', '{"action":"token_revoked","actor_id":"d707eee8-8de6-49fa-a4a6-00d79d6eded8","actor_username":"camelya98@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 11:02:26.495891+00', ''),
	('00000000-0000-0000-0000-000000000000', '7854c9d7-c4b6-48da-a2bc-4df4fa5a1927', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 11:03:40.309558+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dad111d9-a737-4c58-8743-f0e0b02bc999', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 11:03:40.311721+00', ''),
	('00000000-0000-0000-0000-000000000000', '9d199bfc-aa39-4484-9876-1bf9a513fd6e', '{"action":"logout","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-19 11:09:30.572804+00', ''),
	('00000000-0000-0000-0000-000000000000', '46adad79-b356-4d1f-ab2c-e2201e2b294f', '{"action":"login","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-19 11:13:32.085755+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b328da76-1cb5-4699-b63d-d87f61a14f8d', '{"action":"logout","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-19 11:14:47.641547+00', ''),
	('00000000-0000-0000-0000-000000000000', '55d8e072-9d81-4006-bdb6-63de80b98c6f', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 11:23:37.553637+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cb3f1d2a-3498-433b-8039-bcfb751e0a4d', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 11:23:37.556306+00', ''),
	('00000000-0000-0000-0000-000000000000', '0b857f1b-9c17-425f-b58a-d72bfbabcbc5', '{"action":"token_refreshed","actor_id":"7733575e-14a6-48a4-bf21-b7901b8d6714","actor_name":"Alex Suciaghi","actor_username":"suciaghialexandrushorts@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 11:28:22.437137+00', ''),
	('00000000-0000-0000-0000-000000000000', '130e3bd2-b837-4f05-a4da-12407f84ce20', '{"action":"token_revoked","actor_id":"7733575e-14a6-48a4-bf21-b7901b8d6714","actor_name":"Alex Suciaghi","actor_username":"suciaghialexandrushorts@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 11:28:22.440744+00', ''),
	('00000000-0000-0000-0000-000000000000', '0c179abb-3d76-4ec4-9ac7-aff9fca6009b', '{"action":"logout","actor_id":"7733575e-14a6-48a4-bf21-b7901b8d6714","actor_name":"Alex Suciaghi","actor_username":"suciaghialexandrushorts@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-19 11:28:24.931095+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c7133150-2250-4930-b82a-b71e5a35b2af', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-19 11:29:44.011633+00', ''),
	('00000000-0000-0000-0000-000000000000', '9a6b910a-8996-43ad-a0ad-281dc4ea04b8', '{"action":"login","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-19 11:38:58.480994+00', ''),
	('00000000-0000-0000-0000-000000000000', '32dfc1c3-318a-46a3-a0ba-1610244ab0c7', '{"action":"token_refreshed","actor_id":"ab84c874-6fed-45be-9e1d-28da0a041149","actor_username":"elenadaniele_popa@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 11:39:44.353659+00', ''),
	('00000000-0000-0000-0000-000000000000', '1cdaf03b-5bcc-478e-8a14-82d1a8eb8f74', '{"action":"token_revoked","actor_id":"ab84c874-6fed-45be-9e1d-28da0a041149","actor_username":"elenadaniele_popa@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 11:39:44.35431+00', ''),
	('00000000-0000-0000-0000-000000000000', '5c4857cf-d397-45af-849c-5a85b2d480c8', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-19 11:41:14.296115+00', ''),
	('00000000-0000-0000-0000-000000000000', '01ddad3c-b456-4f85-ad03-d570c368cfd6', '{"action":"login","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-19 11:41:20.624447+00', ''),
	('00000000-0000-0000-0000-000000000000', '1a904911-abbb-4583-b3bf-39e0cddf1827', '{"action":"user_confirmation_requested","actor_id":"feea398b-e2c0-4217-be62-0da00ee5ac3b","actor_username":"complet.definit@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 11:58:16.413878+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a77b8054-30d3-4b33-a6ba-ffe57bf84d7f', '{"action":"user_signedup","actor_id":"feea398b-e2c0-4217-be62-0da00ee5ac3b","actor_username":"complet.definit@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-19 11:59:14.676887+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f08cb321-e9c3-4acd-b344-1ad6948e53c0', '{"action":"login","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-19 12:07:00.703242+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c41b6cb4-74d5-447f-8d8c-bcb6d9addf55', '{"action":"token_refreshed","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 12:41:57.688161+00', ''),
	('00000000-0000-0000-0000-000000000000', '3e8eda8d-9f82-4241-b4f2-130abe0f8666', '{"action":"token_revoked","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 12:41:57.691549+00', ''),
	('00000000-0000-0000-0000-000000000000', '554a3fd2-7a6f-4c17-880a-fcb742ee2e74', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 13:13:37.744863+00', ''),
	('00000000-0000-0000-0000-000000000000', '3f4df721-d11a-4c16-b7d9-66e5202b7e02', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 13:13:37.747888+00', ''),
	('00000000-0000-0000-0000-000000000000', '756a2832-51bd-4064-95eb-ecce85f9be64', '{"action":"user_confirmation_requested","actor_id":"65da1664-c0da-4c49-88c8-dce05acc1374","actor_username":"hey_anamaria@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 14:09:03.723621+00', ''),
	('00000000-0000-0000-0000-000000000000', '14281550-c500-4dd2-a48c-07238deccd79', '{"action":"token_refreshed","actor_id":"feea398b-e2c0-4217-be62-0da00ee5ac3b","actor_username":"complet.definit@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 14:11:38.512711+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b134907f-df66-49fb-a4a2-670970e15125', '{"action":"token_revoked","actor_id":"feea398b-e2c0-4217-be62-0da00ee5ac3b","actor_username":"complet.definit@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 14:11:38.516205+00', ''),
	('00000000-0000-0000-0000-000000000000', 'be71ddcc-cc6b-4f4b-ba02-5677e2468113', '{"action":"user_confirmation_requested","actor_id":"783f639b-1cab-407c-b1a9-fa510c00396d","actor_username":"biancanan1979@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 14:12:06.783463+00', ''),
	('00000000-0000-0000-0000-000000000000', '8ae2b8d7-5ba6-479d-945f-b58d0515ef4a', '{"action":"user_signedup","actor_id":"783f639b-1cab-407c-b1a9-fa510c00396d","actor_username":"biancanan1979@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-19 14:12:45.655821+00', ''),
	('00000000-0000-0000-0000-000000000000', '49b6977c-fa7d-44f1-bc2e-60f34599a6af', '{"action":"user_confirmation_requested","actor_id":"8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8","actor_username":"adryma2016@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 14:52:44.305106+00', ''),
	('00000000-0000-0000-0000-000000000000', '63c5669d-8689-4822-8178-e45da0614b50', '{"action":"user_signedup","actor_id":"8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8","actor_username":"adryma2016@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-19 14:53:16.846429+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b8cc7aff-487b-4d89-9798-f253d75c5d1e', '{"action":"token_refreshed","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 14:58:22.99252+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd2d8d1ed-3292-4cc5-a055-9368298fd1ef', '{"action":"token_revoked","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 14:58:22.994608+00', ''),
	('00000000-0000-0000-0000-000000000000', '2c3ac2cf-1739-42ec-bfc4-7ee5209e72e5', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-19 15:08:40.673507+00', ''),
	('00000000-0000-0000-0000-000000000000', '6b2cf49a-6af9-45dc-8cea-555d1296eca1', '{"action":"token_refreshed","actor_id":"feea398b-e2c0-4217-be62-0da00ee5ac3b","actor_username":"complet.definit@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 15:10:07.837972+00', ''),
	('00000000-0000-0000-0000-000000000000', 'eeea2ce8-147a-4c1e-b85e-6ed01a0a3c00', '{"action":"token_revoked","actor_id":"feea398b-e2c0-4217-be62-0da00ee5ac3b","actor_username":"complet.definit@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 15:10:07.839538+00', ''),
	('00000000-0000-0000-0000-000000000000', '3c971337-f8d6-44e4-89be-26429a862adf', '{"action":"user_confirmation_requested","actor_id":"dd8d0335-6696-4fb6-b186-31a0533d9587","actor_username":"adrianakarabuber79@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 15:10:24.359131+00', ''),
	('00000000-0000-0000-0000-000000000000', '1f7e6f7a-1b5a-465e-866e-4cad9e719dc2', '{"action":"user_signedup","actor_id":"dd8d0335-6696-4fb6-b186-31a0533d9587","actor_username":"adrianakarabuber79@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-19 15:10:47.206262+00', ''),
	('00000000-0000-0000-0000-000000000000', '48614a93-e3e0-4714-8ba4-06904650ada9', '{"action":"user_confirmation_requested","actor_id":"1bc4edd2-b5de-4b77-abb8-ffdad01efa4c","actor_username":"valentinfionut@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 15:11:30.34241+00', ''),
	('00000000-0000-0000-0000-000000000000', '6e8cdbd9-e1ec-4ba3-9e9b-661dbfc4ea8e', '{"action":"user_signedup","actor_id":"1bc4edd2-b5de-4b77-abb8-ffdad01efa4c","actor_username":"valentinfionut@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-19 15:12:24.381504+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e881d5b3-fc9d-4e44-bcac-b3cbc0272395', '{"action":"user_confirmation_requested","actor_id":"3e9a53b2-aefd-4282-b37a-ee95f47dfe77","actor_username":"violetapal65@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 15:43:58.957292+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd5e47b51-7310-4fa3-82f0-279cf3a1d7a6', '{"action":"user_signedup","actor_id":"3e9a53b2-aefd-4282-b37a-ee95f47dfe77","actor_username":"violetapal65@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-19 15:44:27.344967+00', ''),
	('00000000-0000-0000-0000-000000000000', '4e3849ef-7eb1-413c-8f9d-b1762e2d664a', '{"action":"user_confirmation_requested","actor_id":"905b3a2e-780e-48f5-b37e-b335d9e97d4a","actor_username":"loryidu@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 15:48:15.441121+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd73066bc-7b0e-4aeb-8be6-d598adc8bbb0', '{"action":"token_refreshed","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 15:59:02.70213+00', ''),
	('00000000-0000-0000-0000-000000000000', '5e81693b-fde1-4623-812b-ee42c85917bc', '{"action":"token_revoked","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 15:59:02.705041+00', ''),
	('00000000-0000-0000-0000-000000000000', '85bda7c2-e045-41ef-8c47-96a0977985f1', '{"action":"token_refreshed","actor_id":"dd8d0335-6696-4fb6-b186-31a0533d9587","actor_username":"adrianakarabuber79@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 16:17:09.395505+00', ''),
	('00000000-0000-0000-0000-000000000000', '77552461-39b9-487d-a22b-d3e9db9217cc', '{"action":"token_revoked","actor_id":"dd8d0335-6696-4fb6-b186-31a0533d9587","actor_username":"adrianakarabuber79@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 16:17:09.398958+00', ''),
	('00000000-0000-0000-0000-000000000000', '95dede65-d2fd-4f21-b24c-18cd1a8674be', '{"action":"user_confirmation_requested","actor_id":"8d983543-4636-4bce-a1b8-d0d5e9c2f88f","actor_username":"office@mobilamoll.ro","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-19 16:31:07.795289+00', ''),
	('00000000-0000-0000-0000-000000000000', '535f7c83-7112-40ac-a4bf-3e70f132169e', '{"action":"user_signedup","actor_id":"8d983543-4636-4bce-a1b8-d0d5e9c2f88f","actor_username":"office@mobilamoll.ro","actor_via_sso":false,"log_type":"team"}', '2025-05-19 16:36:04.011553+00', ''),
	('00000000-0000-0000-0000-000000000000', 'aa9907b9-91cf-4d89-ae04-48801deb70a4', '{"action":"token_refreshed","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 17:17:33.017713+00', ''),
	('00000000-0000-0000-0000-000000000000', '9cf2b562-11fa-4fd4-aae4-4581d4bbdb6f', '{"action":"token_revoked","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 17:17:33.019748+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ec4115b8-1ddb-4ab6-a088-fa8920d9f48f', '{"action":"logout","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-19 17:18:34.448351+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fdc82a9e-cdf2-455f-8cd6-871d46204d56', '{"action":"login","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-19 17:18:40.494228+00', ''),
	('00000000-0000-0000-0000-000000000000', '957d0270-5e71-4236-80ad-52256eb2bc3c', '{"action":"user_signedup","actor_id":"a1e1dcfe-893e-4c00-a4eb-29021630205d","actor_name":"Raluca Mihaela Alexandru","actor_username":"ralucamihaela.alexandru1984@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-19 17:19:58.582245+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fa7e8dac-b534-4453-8e8f-1d03f4b11963', '{"action":"logout","actor_id":"e60876f4-0234-4d74-9cdb-37d800195a94","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-19 17:22:23.195158+00', ''),
	('00000000-0000-0000-0000-000000000000', '9f3e533b-0d08-40cc-9f7e-ec508a81106d', '{"action":"token_refreshed","actor_id":"8d983543-4636-4bce-a1b8-d0d5e9c2f88f","actor_username":"office@mobilamoll.ro","actor_via_sso":false,"log_type":"token"}', '2025-05-19 17:34:53.754348+00', ''),
	('00000000-0000-0000-0000-000000000000', 'eae297f0-832d-44f5-b25b-99b16a7ee894', '{"action":"token_revoked","actor_id":"8d983543-4636-4bce-a1b8-d0d5e9c2f88f","actor_username":"office@mobilamoll.ro","actor_via_sso":false,"log_type":"token"}', '2025-05-19 17:34:53.75693+00', ''),
	('00000000-0000-0000-0000-000000000000', '45721158-59c2-4115-afa9-9bf3b43f1ec1', '{"action":"token_refreshed","actor_id":"dd8d0335-6696-4fb6-b186-31a0533d9587","actor_username":"adrianakarabuber79@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 17:36:00.791419+00', ''),
	('00000000-0000-0000-0000-000000000000', '45450b92-a347-4280-b43b-1338d9ce7d26', '{"action":"token_revoked","actor_id":"dd8d0335-6696-4fb6-b186-31a0533d9587","actor_username":"adrianakarabuber79@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 17:36:00.792928+00', ''),
	('00000000-0000-0000-0000-000000000000', '20323586-0736-4d23-ae67-095dd32f0aa6', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 17:42:49.076133+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b6c5ab76-c5bb-4bb9-88b3-1b25f8d76002', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-19 17:42:49.079145+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dfb8ea53-8b6d-481d-bd50-f7439a68f538', '{"action":"logout","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-19 17:53:56.963542+00', ''),
	('00000000-0000-0000-0000-000000000000', '2a779fc7-2301-466b-aecd-e52bc6ad3293', '{"action":"login","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-19 17:54:02.100879+00', ''),
	('00000000-0000-0000-0000-000000000000', '70064bec-4e0e-4e40-bf4f-846687f6c443', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 01:03:36.583952+00', ''),
	('00000000-0000-0000-0000-000000000000', '14de01d8-bc83-4a50-b5af-d9ca7b5cce26', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 01:03:36.58875+00', ''),
	('00000000-0000-0000-0000-000000000000', '25a12462-bacb-48fc-be37-d1d4571ee5b8', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-20 01:33:16.218017+00', ''),
	('00000000-0000-0000-0000-000000000000', '9f79ec73-ad9b-4693-885b-6642ba8406ee', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 03:00:14.723173+00', ''),
	('00000000-0000-0000-0000-000000000000', 'bc5d49b2-3134-43e2-99d3-5aeea756c367', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 03:00:14.727508+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e92b3ccf-343c-4fce-b83c-c2d3775aeca2', '{"action":"token_refreshed","actor_id":"1d4e4d74-493a-4758-a5e1-3229a81bae5d","actor_username":"inna.medeea.lupu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 03:52:07.202256+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b218a9db-4674-44c4-9ef4-12a5116f8136', '{"action":"token_revoked","actor_id":"1d4e4d74-493a-4758-a5e1-3229a81bae5d","actor_username":"inna.medeea.lupu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 03:52:07.20446+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f0227d7d-d2bf-4bd3-b2b4-edd2988125fa', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 04:12:28.277754+00', ''),
	('00000000-0000-0000-0000-000000000000', '2aa2b187-76e4-40cb-9b4d-4a231fa6d37c', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 04:12:28.280437+00', ''),
	('00000000-0000-0000-0000-000000000000', '30a2fb4a-bc13-47f9-8b2b-9fd954f3c0fc', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-20 04:25:16.705052+00', ''),
	('00000000-0000-0000-0000-000000000000', '6803932f-5819-43d2-bab2-75e82b66cc7e', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-20 04:25:19.011517+00', ''),
	('00000000-0000-0000-0000-000000000000', '95307b08-e6fe-428b-bad0-b88eb693604f', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-20 04:27:37.213895+00', ''),
	('00000000-0000-0000-0000-000000000000', '0120007f-f74a-401d-b660-06e3f499acc7', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-20 04:27:55.548767+00', ''),
	('00000000-0000-0000-0000-000000000000', '58815163-a074-4ff4-9b9d-690807a0e6eb', '{"action":"token_refreshed","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 05:09:32.159956+00', ''),
	('00000000-0000-0000-0000-000000000000', '748462d5-a2dc-4c9c-856a-63b31cb63cb0', '{"action":"token_revoked","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 05:09:32.161446+00', ''),
	('00000000-0000-0000-0000-000000000000', '84c28763-3348-41a6-a7ff-82d73bcbf004', '{"action":"logout","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-20 05:09:43.402068+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f389eccd-b556-4757-a011-c39e84528de5', '{"action":"login","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-20 05:23:18.317072+00', ''),
	('00000000-0000-0000-0000-000000000000', '34be5bb1-6ed2-4d3d-aefd-e6bc74d8c85b', '{"action":"logout","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-20 05:25:15.910776+00', ''),
	('00000000-0000-0000-0000-000000000000', '20de9e0d-a2fb-4a5a-80a7-47abfb86fb86', '{"action":"user_repeated_signup","actor_id":"852c0593-32ee-4947-9400-a99736f6c907","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 05:27:01.448255+00', ''),
	('00000000-0000-0000-0000-000000000000', '8088e35c-8ace-440e-abe6-8c0360419fb7', '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role","actor_via_sso":false,"log_type":"team","traits":{"user_email":"suciaghialex@gmail.com","user_id":"852c0593-32ee-4947-9400-a99736f6c907","user_phone":""}}', '2025-05-20 05:29:35.739841+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fbaeb941-d4de-4c86-b0fb-8c49b9421876', '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role","actor_via_sso":false,"log_type":"team","traits":{"user_email":"hellosuciaghi@gmail.com","user_id":"2d15cf78-b2a0-4014-8c9e-95738b853eb9","user_phone":""}}', '2025-05-20 05:30:00.219561+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c9fb212d-e7b9-4692-a2c5-7f26c041363e', '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role","actor_via_sso":false,"log_type":"team","traits":{"user_email":"sirwildyt@gmail.com","user_id":"0de89068-d0da-47c5-964a-0a5d5da5cdd0","user_phone":""}}', '2025-05-20 05:30:00.254621+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b8daec16-7ef5-450b-bc76-b0223f32f18b', '{"action":"user_confirmation_requested","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 05:30:09.465706+00', ''),
	('00000000-0000-0000-0000-000000000000', '4de533b1-6518-4e5d-b6be-b8555ed50b54', '{"action":"user_signedup","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 05:32:51.05389+00', ''),
	('00000000-0000-0000-0000-000000000000', '00cef9b5-1247-4eec-b4a6-b9dec2853252', '{"action":"token_refreshed","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 05:36:33.571674+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ddc5adff-aa15-48d1-9095-3200da714ec0', '{"action":"token_revoked","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 05:36:33.572616+00', ''),
	('00000000-0000-0000-0000-000000000000', '88e798fc-4dbf-4c17-97a0-9b6dae1ce440', '{"action":"token_refreshed","actor_id":"1d4e4d74-493a-4758-a5e1-3229a81bae5d","actor_username":"inna.medeea.lupu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 05:38:36.991348+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a984f754-bbf2-428f-90f9-99d7b69a8e0a', '{"action":"token_revoked","actor_id":"1d4e4d74-493a-4758-a5e1-3229a81bae5d","actor_username":"inna.medeea.lupu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 05:38:36.993681+00', ''),
	('00000000-0000-0000-0000-000000000000', '8b872e86-1c0b-4794-b3a2-44a3ab270e2e', '{"action":"user_confirmation_requested","actor_id":"7f541d24-fa47-444f-9ca4-f4f7bc3f4dde","actor_username":"ioanalexandruturcu@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 06:09:41.955661+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f81ea0ed-4320-46d7-a8d5-b8ffeeca2afc', '{"action":"user_signedup","actor_id":"7f541d24-fa47-444f-9ca4-f4f7bc3f4dde","actor_username":"ioanalexandruturcu@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 06:34:37.292875+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f83d347c-4bbd-442a-81f9-bbe4694b4dbc', '{"action":"user_confirmation_requested","actor_id":"d3275dfe-f4df-44fc-acaa-659e92369e66","actor_username":"danutjilavu@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 06:34:44.758223+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd03c5546-1b7d-459e-978a-aaf7ad7b5533', '{"action":"user_signedup","actor_id":"d3275dfe-f4df-44fc-acaa-659e92369e66","actor_username":"danutjilavu@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 06:35:10.145423+00', ''),
	('00000000-0000-0000-0000-000000000000', '893f46f0-e84e-4e1b-8e1b-a64e8a82120e', '{"action":"token_refreshed","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 06:36:00.607434+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e08359d7-33ac-43f7-b7e3-3b2080cebf96', '{"action":"token_revoked","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 06:36:00.6081+00', ''),
	('00000000-0000-0000-0000-000000000000', '9b11ec87-e37a-4a54-a906-c25950d79434', '{"action":"token_refreshed","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 06:48:35.309076+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ec55a876-3eb2-4447-ac70-8f74f66d0725', '{"action":"token_revoked","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 06:48:35.313263+00', ''),
	('00000000-0000-0000-0000-000000000000', '932b1eb7-b232-463d-b410-46bb3426ee07', '{"action":"user_signedup","actor_id":"622d14e0-2b33-4c8b-81d5-231a707fd100","actor_name":"Gabriela Pogaci","actor_username":"pogaci2@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-20 07:02:39.050678+00', ''),
	('00000000-0000-0000-0000-000000000000', '3463b233-9fbe-47f8-8060-a5344e32de44', '{"action":"user_signedup","actor_id":"072aa24d-bfc3-4b0c-93f2-1435906d8381","actor_name":"Diana Olivia Simu","actor_username":"dianasimutm@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-20 07:34:37.657942+00', ''),
	('00000000-0000-0000-0000-000000000000', '752de30d-6ff6-48d1-a9c7-3076228b551a', '{"action":"token_refreshed","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 07:35:21.299454+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f12c7b50-b843-46bf-8a0b-e766e2d550fa', '{"action":"token_revoked","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 07:35:21.300036+00', ''),
	('00000000-0000-0000-0000-000000000000', '29b3543a-1dc8-408a-9729-76440502bb25', '{"action":"logout","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-20 07:40:31.851875+00', ''),
	('00000000-0000-0000-0000-000000000000', '4add2412-3be3-461c-bb0f-17f03aeef449', '{"action":"login","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-20 07:40:34.10216+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c3cbccb2-9fd1-4a31-a535-21143be83bcf', '{"action":"token_refreshed","actor_id":"c07e8742-9b26-4257-80d8-81ea920e3722","actor_name":"Cristina Buzea","actor_username":"cbuzea30@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 07:43:51.165809+00', ''),
	('00000000-0000-0000-0000-000000000000', '8f2abf50-8b25-4522-ace5-1532fec99eac', '{"action":"token_revoked","actor_id":"c07e8742-9b26-4257-80d8-81ea920e3722","actor_name":"Cristina Buzea","actor_username":"cbuzea30@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 07:43:51.169369+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f1694cd6-ded6-4bdc-9c5e-346919b0cadc', '{"action":"logout","actor_id":"76f53ea1-d6bf-4bf7-b88a-918e4062766e","actor_username":"secrets.of.life.f2p@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-20 07:45:58.5606+00', ''),
	('00000000-0000-0000-0000-000000000000', '089e2917-9b9e-4781-b311-dff6f4e3f9cc', '{"action":"user_confirmation_requested","actor_id":"905b3a2e-780e-48f5-b37e-b335d9e97d4a","actor_username":"loryidu@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 07:47:13.628915+00', ''),
	('00000000-0000-0000-0000-000000000000', '882b66cc-5d45-4dda-8367-6cc4beac0533', '{"action":"user_signedup","actor_id":"905b3a2e-780e-48f5-b37e-b335d9e97d4a","actor_username":"loryidu@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 07:47:56.397179+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ad84b5ed-f207-44d7-ac80-e220ede2a655', '{"action":"token_refreshed","actor_id":"8e441edf-2d91-4551-a4e6-924316cd2090","actor_username":"contactandreigeorge@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 07:48:59.598028+00', ''),
	('00000000-0000-0000-0000-000000000000', '78a6e370-eb3e-4eb0-9565-a3cb577d556b', '{"action":"token_revoked","actor_id":"8e441edf-2d91-4551-a4e6-924316cd2090","actor_username":"contactandreigeorge@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 07:48:59.601569+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c7bdda30-b614-4514-b0eb-c197b58398e0', '{"action":"token_refreshed","actor_id":"8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8","actor_username":"adryma2016@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 07:56:47.984121+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e2c95064-16f3-4e6f-9903-ef0cb71cfce0', '{"action":"token_revoked","actor_id":"8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8","actor_username":"adryma2016@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 07:56:47.986163+00', ''),
	('00000000-0000-0000-0000-000000000000', '5dfb1a2f-a216-476a-bea5-0b30eb7cf423', '{"action":"token_refreshed","actor_id":"622d14e0-2b33-4c8b-81d5-231a707fd100","actor_name":"Gabriela Pogaci","actor_username":"pogaci2@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 08:00:56.648715+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ca19fbfe-a279-4fdd-809c-a3d16791a37e', '{"action":"token_revoked","actor_id":"622d14e0-2b33-4c8b-81d5-231a707fd100","actor_name":"Gabriela Pogaci","actor_username":"pogaci2@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 08:00:56.6522+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c2e3e9eb-e301-4d32-a61c-78bef9964a29', '{"action":"token_refreshed","actor_id":"d3275dfe-f4df-44fc-acaa-659e92369e66","actor_username":"danutjilavu@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 08:19:01.790666+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e3b337a2-9974-4c38-9f9b-6daaaa6e2b64', '{"action":"token_revoked","actor_id":"d3275dfe-f4df-44fc-acaa-659e92369e66","actor_username":"danutjilavu@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 08:19:01.792596+00', ''),
	('00000000-0000-0000-0000-000000000000', '3ff601a4-4134-42ba-a8a7-559ff0d86415', '{"action":"token_refreshed","actor_id":"072aa24d-bfc3-4b0c-93f2-1435906d8381","actor_name":"Diana Olivia Simu","actor_username":"dianasimutm@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 08:46:16.422862+00', ''),
	('00000000-0000-0000-0000-000000000000', '42a57bb0-11b7-4226-8ed3-212e85cd3843', '{"action":"token_revoked","actor_id":"072aa24d-bfc3-4b0c-93f2-1435906d8381","actor_name":"Diana Olivia Simu","actor_username":"dianasimutm@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 08:46:16.425689+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd60e8fec-e513-4627-8173-19890cb6dccf', '{"action":"token_refreshed","actor_id":"072aa24d-bfc3-4b0c-93f2-1435906d8381","actor_name":"Diana Olivia Simu","actor_username":"dianasimutm@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 11:04:53.829737+00', ''),
	('00000000-0000-0000-0000-000000000000', '0d970206-bea5-4032-8a5d-338bdcc23780', '{"action":"token_revoked","actor_id":"072aa24d-bfc3-4b0c-93f2-1435906d8381","actor_name":"Diana Olivia Simu","actor_username":"dianasimutm@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 11:04:53.836094+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b04372d3-1ad3-412d-8af0-0a2db8acb385', '{"action":"user_confirmation_requested","actor_id":"ae26134b-38c8-4748-8770-5b73d79cae08","actor_username":"teomury@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 11:49:42.509533+00', ''),
	('00000000-0000-0000-0000-000000000000', '01368eb9-3d58-4141-80ef-86860ce0cd87', '{"action":"user_signedup","actor_id":"ae26134b-38c8-4748-8770-5b73d79cae08","actor_username":"teomury@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 11:49:51.639754+00', ''),
	('00000000-0000-0000-0000-000000000000', '3573c350-e814-4d5b-958c-b42714c02520', '{"action":"login","actor_id":"ae26134b-38c8-4748-8770-5b73d79cae08","actor_username":"teomury@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-20 11:50:33.879196+00', ''),
	('00000000-0000-0000-0000-000000000000', '9c3c904e-44ac-4a85-91ab-1bacf9205cce', '{"action":"token_refreshed","actor_id":"d3275dfe-f4df-44fc-acaa-659e92369e66","actor_username":"danutjilavu@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 11:58:44.137111+00', ''),
	('00000000-0000-0000-0000-000000000000', '2d379e67-defc-40b6-8047-52c1ea99e707', '{"action":"token_revoked","actor_id":"d3275dfe-f4df-44fc-acaa-659e92369e66","actor_username":"danutjilavu@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 11:58:44.139519+00', ''),
	('00000000-0000-0000-0000-000000000000', '5bcf463b-a384-4ba0-9246-ee090150be0f', '{"action":"user_signedup","actor_id":"7b00956b-eafb-4d19-aed0-67dad9ab51ee","actor_name":"Maria Lica","actor_username":"lica.mara.c02@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-20 12:19:40.69948+00', ''),
	('00000000-0000-0000-0000-000000000000', '277196b2-d209-4367-86db-0cd7c376d643', '{"action":"user_confirmation_requested","actor_id":"648f53d8-8151-4405-a4bc-b6f0762670e7","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 13:08:14.363783+00', ''),
	('00000000-0000-0000-0000-000000000000', 'df5d43bb-9172-45ce-a77f-f6f45ff21c49', '{"action":"token_refreshed","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 13:13:48.131096+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd3587e9d-f67a-4004-a8b9-1afb866c4a76', '{"action":"token_revoked","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 13:13:48.131969+00', ''),
	('00000000-0000-0000-0000-000000000000', 'adaaa740-3875-480a-a949-3641828afabc', '{"action":"token_refreshed","actor_id":"7b00956b-eafb-4d19-aed0-67dad9ab51ee","actor_name":"Maria Lica","actor_username":"lica.mara.c02@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 13:23:38.356635+00', ''),
	('00000000-0000-0000-0000-000000000000', 'de73fea3-f8be-4c5f-a757-d9c71aebf9b7', '{"action":"token_revoked","actor_id":"7b00956b-eafb-4d19-aed0-67dad9ab51ee","actor_name":"Maria Lica","actor_username":"lica.mara.c02@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 13:23:38.358144+00', ''),
	('00000000-0000-0000-0000-000000000000', 'bcae248c-18e9-4281-bc86-19119cd09bcf', '{"action":"user_confirmation_requested","actor_id":"648f53d8-8151-4405-a4bc-b6f0762670e7","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 13:27:38.318597+00', ''),
	('00000000-0000-0000-0000-000000000000', '0eb68433-3b16-42c6-98fa-52f27f92723f', '{"action":"user_confirmation_requested","actor_id":"682d23b2-3bb3-4f55-9f23-5b7689983e82","actor_username":"alexandra.pandelea88@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 13:30:14.58894+00', ''),
	('00000000-0000-0000-0000-000000000000', '926cf19e-8c3d-47ad-b1e0-0463c8616390', '{"action":"user_signedup","actor_id":"682d23b2-3bb3-4f55-9f23-5b7689983e82","actor_username":"alexandra.pandelea88@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 13:30:25.112592+00', ''),
	('00000000-0000-0000-0000-000000000000', 'eb29e5b4-e094-4907-b884-926b81a206dc', '{"action":"user_confirmation_requested","actor_id":"648f53d8-8151-4405-a4bc-b6f0762670e7","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user"}', '2025-05-20 13:32:28.194703+00', ''),
	('00000000-0000-0000-0000-000000000000', '22acb1bb-ab3d-432a-b61c-f33323d30d42', '{"action":"user_confirmation_requested","actor_id":"648f53d8-8151-4405-a4bc-b6f0762670e7","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 13:33:52.343866+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b0bfb56b-0d47-4895-95ae-1cb0ff98c3b3', '{"action":"user_confirmation_requested","actor_id":"e86ffac1-e376-437c-9244-e20808713d01","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 13:51:08.921365+00', ''),
	('00000000-0000-0000-0000-000000000000', 'eb903521-fbc5-4b42-abe6-cd6d8ec3e402', '{"action":"user_confirmation_requested","actor_id":"e86ffac1-e376-437c-9244-e20808713d01","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 13:54:20.244076+00', ''),
	('00000000-0000-0000-0000-000000000000', '51df38e7-2239-4e29-9fd8-9f309587afe8', '{"action":"user_confirmation_requested","actor_id":"e86ffac1-e376-437c-9244-e20808713d01","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user"}', '2025-05-20 13:58:22.846022+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cca921f2-fd8f-4718-8054-3e333cae95b0', '{"action":"user_confirmation_requested","actor_id":"51646903-26c9-45aa-9ca7-59862c410bd9","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 13:58:59.572564+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd908f2d9-4daf-499b-ae2c-a9feae036a46', '{"action":"user_confirmation_requested","actor_id":"a58debde-e1f6-48b3-8d38-d00fc7a5a1a8","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:00:20.150496+00', ''),
	('00000000-0000-0000-0000-000000000000', '05c13ef5-a661-4a22-b2cb-d6442465c913', '{"action":"user_confirmation_requested","actor_id":"a58debde-e1f6-48b3-8d38-d00fc7a5a1a8","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"user"}', '2025-05-20 14:01:23.556267+00', ''),
	('00000000-0000-0000-0000-000000000000', '77a22299-1c01-4f15-b76e-3894298e6abd', '{"action":"user_confirmation_requested","actor_id":"7f264237-d25d-4b36-b486-357cacb964b0","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:01:48.767089+00', ''),
	('00000000-0000-0000-0000-000000000000', '126e617b-538e-47e1-b947-fb007f6aa5c1', '{"action":"user_confirmation_requested","actor_id":"e7975455-1ca5-47e9-a7bb-2784ea0480ab","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:04:49.126221+00', ''),
	('00000000-0000-0000-0000-000000000000', '3a203f5d-9df5-4eb0-bff6-463051c992a9', '{"action":"user_confirmation_requested","actor_id":"c68c810b-543c-4ad9-a3cd-35f9d7e1a01d","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:07:26.685509+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e5f1089b-4c5d-47fa-9ab7-aaf69e3e2422', '{"action":"user_confirmation_requested","actor_id":"b2052a23-db81-431e-b6ec-5074ff18e339","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:09:25.81966+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b891dd5f-7f0f-4717-8618-30dd32fbf926', '{"action":"token_refreshed","actor_id":"7f541d24-fa47-444f-9ca4-f4f7bc3f4dde","actor_username":"ioanalexandruturcu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 14:10:18.993295+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd66e5412-2e67-42ee-8405-bed986af8ba3', '{"action":"token_revoked","actor_id":"7f541d24-fa47-444f-9ca4-f4f7bc3f4dde","actor_username":"ioanalexandruturcu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 14:10:18.993935+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f55fd0af-4744-41e9-97bb-e824f64e3432', '{"action":"user_signedup","actor_id":"b2052a23-db81-431e-b6ec-5074ff18e339","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 14:10:41.013694+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cd7e84cd-6fd1-4620-82df-7e744b3c6ee9', '{"action":"user_confirmation_requested","actor_id":"5372f649-131e-4d51-9dc0-86db89839be1","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:12:38.509178+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a37c8a6f-c425-478d-9c70-033a39b22f4a', '{"action":"user_signedup","actor_id":"5372f649-131e-4d51-9dc0-86db89839be1","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 14:12:56.457885+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f7136ca0-5649-4527-a109-a4687428f10b', '{"action":"user_signedup","actor_id":"9a864e87-0832-42f6-9719-df4a03a3a38d","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-20 14:15:32.749122+00', ''),
	('00000000-0000-0000-0000-000000000000', '80b997e1-3a98-4a73-b80b-a51d3b716f51', '{"action":"logout","actor_id":"9a864e87-0832-42f6-9719-df4a03a3a38d","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-20 14:15:40.385083+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c0edfd8c-bf84-4492-bac6-149e74e53f01', '{"action":"user_signedup","actor_id":"35612faa-9e71-4a00-adf1-41d4713243c9","actor_name":"Lao Water","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-20 14:15:49.114589+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b44db629-e5e6-47b3-afbf-7e7b8d16e5f1', '{"action":"user_confirmation_requested","actor_id":"cb6ba064-df74-429b-9b6e-2e04b0050986","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:19:54.359819+00', ''),
	('00000000-0000-0000-0000-000000000000', '12fce3ef-3301-4d6d-852b-8743b1b087c5', '{"action":"user_signedup","actor_id":"cb6ba064-df74-429b-9b6e-2e04b0050986","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 14:20:04.514521+00', ''),
	('00000000-0000-0000-0000-000000000000', '3e23e838-14e1-4197-8a53-669e552eb94a', '{"action":"token_refreshed","actor_id":"dd8d0335-6696-4fb6-b186-31a0533d9587","actor_username":"adrianakarabuber79@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 14:22:40.11807+00', ''),
	('00000000-0000-0000-0000-000000000000', '4a882c1c-4cfa-4771-a3f9-b8c8ef62bbb1', '{"action":"token_revoked","actor_id":"dd8d0335-6696-4fb6-b186-31a0533d9587","actor_username":"adrianakarabuber79@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 14:22:40.12022+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a060383d-e9d2-461c-801d-297832588abf', '{"action":"user_confirmation_requested","actor_id":"ed30f2c8-2caa-4339-bfff-27cfadadadac","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:25:20.484087+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd7340888-8884-4bf2-8114-7d2ffed46583', '{"action":"user_signedup","actor_id":"ed30f2c8-2caa-4339-bfff-27cfadadadac","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 14:25:32.724893+00', ''),
	('00000000-0000-0000-0000-000000000000', '7d39bb94-c2eb-4f2d-88df-251e0ba9b2e5', '{"action":"login","actor_id":"ed30f2c8-2caa-4339-bfff-27cfadadadac","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-20 14:25:55.362028+00', ''),
	('00000000-0000-0000-0000-000000000000', '75d778e3-58d8-4504-b203-e6d450b7cf3f', '{"action":"user_confirmation_requested","actor_id":"98c98762-7aff-405a-ab08-413db35f49db","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:41:53.796689+00', ''),
	('00000000-0000-0000-0000-000000000000', '826baa94-31c4-4c7e-acd7-6c7265815fac', '{"action":"user_confirmation_requested","actor_id":"98c98762-7aff-405a-ab08-413db35f49db","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:42:54.033956+00', ''),
	('00000000-0000-0000-0000-000000000000', '2cc2c053-17c5-4647-b1cd-57bf3c86babe', '{"action":"user_signedup","actor_id":"98c98762-7aff-405a-ab08-413db35f49db","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 14:43:09.187492+00', ''),
	('00000000-0000-0000-0000-000000000000', '9cd2c511-b99b-4261-b1a4-853f1baf5989', '{"action":"user_confirmation_requested","actor_id":"4c5e78e2-e62d-4fba-b156-3f2fb316fa80","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:44:12.739742+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ca816d37-862e-4f84-828c-e332f5ae5258', '{"action":"user_confirmation_requested","actor_id":"09eedaa9-919e-47c7-af84-ee5c0e894509","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:44:42.812784+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cd7a244e-d663-43f9-a9a4-a8f0619a466c', '{"action":"user_signedup","actor_id":"4c5e78e2-e62d-4fba-b156-3f2fb316fa80","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 14:46:19.103547+00', ''),
	('00000000-0000-0000-0000-000000000000', '7fe5c247-64fc-48dc-88ae-7e1d16a2c36c', '{"action":"logout","actor_id":"4c5e78e2-e62d-4fba-b156-3f2fb316fa80","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-20 14:46:33.11113+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b0e6b2d7-1c36-495e-9210-d5a1c3fc5047', '{"action":"user_confirmation_requested","actor_id":"28a0fdf8-c258-4c18-9c84-d464c4bb6403","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:49:02.06502+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c18090be-3175-41a8-bf07-f87797ca5e1c', '{"action":"user_signedup","actor_id":"28a0fdf8-c258-4c18-9c84-d464c4bb6403","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 14:49:16.972175+00', ''),
	('00000000-0000-0000-0000-000000000000', '3e4e667a-f8b5-40d2-b558-84c7ef8ead4c', '{"action":"logout","actor_id":"28a0fdf8-c258-4c18-9c84-d464c4bb6403","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-20 14:49:20.038535+00', ''),
	('00000000-0000-0000-0000-000000000000', '16c1af03-4042-45c9-a9e8-18ea6fd58ac1', '{"action":"user_confirmation_requested","actor_id":"f9c8c229-791a-4468-bbf6-2b328e04593e","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:49:38.25617+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dffe714c-e98a-4b78-bb11-86a95581cce6', '{"action":"user_confirmation_requested","actor_id":"6c5c6807-d15a-41fd-87d2-adcc84daa1db","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:50:51.988897+00', ''),
	('00000000-0000-0000-0000-000000000000', '4d0009db-b859-44cb-ad9a-f45bf46d7713', '{"action":"user_confirmation_requested","actor_id":"a78e170e-24b7-410f-a4f4-d732ca24b29b","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 14:51:08.311482+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd058f540-3d9d-4ccc-828a-6685400de742', '{"action":"token_refreshed","actor_id":"072aa24d-bfc3-4b0c-93f2-1435906d8381","actor_name":"Diana Olivia Simu","actor_username":"dianasimutm@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 14:59:53.999333+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b79b778e-ea51-4054-9dbe-ecbce9d5b491', '{"action":"token_revoked","actor_id":"072aa24d-bfc3-4b0c-93f2-1435906d8381","actor_name":"Diana Olivia Simu","actor_username":"dianasimutm@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 14:59:54.00484+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a18c8c1d-daca-4a48-ad8d-768381f3a033', '{"action":"token_refreshed","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 15:26:36.817053+00', ''),
	('00000000-0000-0000-0000-000000000000', '049b6d60-a357-4534-8e0c-71754d2e0030', '{"action":"token_revoked","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 15:26:36.819092+00', ''),
	('00000000-0000-0000-0000-000000000000', '47078a0b-7a7e-4e03-afe9-a9d5feab3c3d', '{"action":"user_repeated_signup","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 15:27:40.248942+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c4bcd198-45d7-48b8-bcd4-57f408d4f316', '{"action":"user_confirmation_requested","actor_id":"5e44c884-419b-40e6-989b-6bdb9682f647","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 15:30:34.629267+00', ''),
	('00000000-0000-0000-0000-000000000000', '2e88db9e-a348-4208-ba14-2382668755e9', '{"action":"user_confirmation_requested","actor_id":"5e44c884-419b-40e6-989b-6bdb9682f647","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 15:31:38.341783+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f7c3cb6a-552d-4bdb-b15a-ca4b0fe5dcb5', '{"action":"user_signedup","actor_id":"5e44c884-419b-40e6-989b-6bdb9682f647","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 15:32:51.355661+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cbe9320b-fa51-4512-83ee-17819fe5bf0f', '{"action":"user_confirmation_requested","actor_id":"fc5b658b-dd63-47b7-bfd8-56cc05fe2eb7","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 15:37:16.401642+00', ''),
	('00000000-0000-0000-0000-000000000000', '7e97b974-346b-412a-a861-8a0b81604c5a', '{"action":"user_confirmation_requested","actor_id":"d605c7ff-b858-475b-8436-0db61674fc41","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 15:39:32.461696+00', ''),
	('00000000-0000-0000-0000-000000000000', '0679a586-b3d5-4d23-9610-1f77989fcd23', '{"action":"user_confirmation_requested","actor_id":"cff988c4-74c7-4d89-8ea5-ca57af9c7a7a","actor_username":"renataiancupsiholog@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 15:40:45.437021+00', ''),
	('00000000-0000-0000-0000-000000000000', 'bee49358-dade-4953-9b69-625ef0630348', '{"action":"user_signedup","actor_id":"cff988c4-74c7-4d89-8ea5-ca57af9c7a7a","actor_username":"renataiancupsiholog@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 15:40:54.510075+00', ''),
	('00000000-0000-0000-0000-000000000000', '56727849-aa13-47c9-a4aa-b29d54bb4642', '{"action":"token_refreshed","actor_id":"dd8d0335-6696-4fb6-b186-31a0533d9587","actor_username":"adrianakarabuber79@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 15:52:34.316061+00', ''),
	('00000000-0000-0000-0000-000000000000', '23da4cfe-36a8-45db-b1ea-ea2e420c326d', '{"action":"token_revoked","actor_id":"dd8d0335-6696-4fb6-b186-31a0533d9587","actor_username":"adrianakarabuber79@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 15:52:34.318512+00', ''),
	('00000000-0000-0000-0000-000000000000', 'df30cebd-0f6f-419f-a076-1b274eca0a57', '{"action":"user_confirmation_requested","actor_id":"d605c7ff-b858-475b-8436-0db61674fc41","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 15:54:45.973237+00', ''),
	('00000000-0000-0000-0000-000000000000', '3d60bacd-3418-4657-91b9-7ddc549e9cae', '{"action":"user_confirmation_requested","actor_id":"d605c7ff-b858-475b-8436-0db61674fc41","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 15:56:38.224313+00', ''),
	('00000000-0000-0000-0000-000000000000', 'da89bf3a-0d4f-4492-978b-5ab56be68bd0', '{"action":"user_confirmation_requested","actor_id":"a4df9a8d-cf15-43fc-97eb-6c0e8c075f6f","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 16:05:01.119401+00', ''),
	('00000000-0000-0000-0000-000000000000', '88014987-4ed9-4c53-b84a-bc2150977d6c', '{"action":"user_confirmation_requested","actor_id":"a4df9a8d-cf15-43fc-97eb-6c0e8c075f6f","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 16:06:24.789107+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a17ab14d-8ccf-4f73-8f99-ca8c6a1fdf2d', '{"action":"user_confirmation_requested","actor_id":"a4df9a8d-cf15-43fc-97eb-6c0e8c075f6f","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 16:09:42.146106+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e7ccb5f5-b00e-4ef5-9eea-cfcf8135b507', '{"action":"user_confirmation_requested","actor_id":"a4df9a8d-cf15-43fc-97eb-6c0e8c075f6f","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 16:12:32.081537+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dac7e613-36f8-4dd0-bfe1-66e93db0bea4', '{"action":"user_confirmation_requested","actor_id":"25e67045-a22c-473f-81a5-48e00c7368a5","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 16:27:41.873583+00', ''),
	('00000000-0000-0000-0000-000000000000', '89ab9638-494a-45be-ac76-3d686dfa7612', '{"action":"user_confirmation_requested","actor_id":"25e67045-a22c-473f-81a5-48e00c7368a5","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user"}', '2025-05-20 16:28:53.011205+00', ''),
	('00000000-0000-0000-0000-000000000000', '4d82735e-d2ed-4c3f-9a4d-1811053c0076', '{"action":"user_confirmation_requested","actor_id":"82ecc83e-979b-49c3-ae81-5676f59c927c","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 16:34:13.66987+00', ''),
	('00000000-0000-0000-0000-000000000000', 'db3abe07-cae9-4b30-9fd2-382c43fb123a', '{"action":"user_confirmation_requested","actor_id":"82ecc83e-979b-49c3-ae81-5676f59c927c","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user"}', '2025-05-20 16:41:00.749357+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f32f177b-4ce5-4f2a-b65c-77498b3b93e7', '{"action":"token_refreshed","actor_id":"cff988c4-74c7-4d89-8ea5-ca57af9c7a7a","actor_username":"renataiancupsiholog@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 16:43:21.889047+00', ''),
	('00000000-0000-0000-0000-000000000000', '4be5c2fd-8748-454d-9e62-4d0b38d5b875', '{"action":"token_revoked","actor_id":"cff988c4-74c7-4d89-8ea5-ca57af9c7a7a","actor_username":"renataiancupsiholog@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 16:43:21.889705+00', ''),
	('00000000-0000-0000-0000-000000000000', '84b25cc0-f32b-42a8-a81d-4d244af62c00', '{"action":"token_refreshed","actor_id":"072aa24d-bfc3-4b0c-93f2-1435906d8381","actor_name":"Diana Olivia Simu","actor_username":"dianasimutm@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 17:29:50.00199+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c08bce2d-4457-48e3-872e-40cdc0022e45', '{"action":"token_revoked","actor_id":"072aa24d-bfc3-4b0c-93f2-1435906d8381","actor_name":"Diana Olivia Simu","actor_username":"dianasimutm@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 17:29:50.005624+00', ''),
	('00000000-0000-0000-0000-000000000000', '14ddf1ee-ec0e-4034-afff-8f040d758d3d', '{"action":"user_confirmation_requested","actor_id":"1aa4f7e2-f7f1-4b27-a7bd-f2595a5fdfce","actor_username":"d_lupu@ymail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 18:42:57.466964+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cbf0d910-30c0-4056-8880-4fd8409b8b26', '{"action":"user_signedup","actor_id":"1aa4f7e2-f7f1-4b27-a7bd-f2595a5fdfce","actor_username":"d_lupu@ymail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 18:43:57.472774+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f99ffad9-5866-403c-b25f-006088b94fe4', '{"action":"user_confirmation_requested","actor_id":"82ecc83e-979b-49c3-ae81-5676f59c927c","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 18:52:47.307933+00', ''),
	('00000000-0000-0000-0000-000000000000', '10ce2d06-c631-4aa7-8fd1-4f46a6f56d9d', '{"action":"user_signedup","actor_id":"82ecc83e-979b-49c3-ae81-5676f59c927c","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 18:59:29.016205+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b44d9b28-c857-4cb8-a8d6-94052f24ea6e', '{"action":"login","actor_id":"1aa4f7e2-f7f1-4b27-a7bd-f2595a5fdfce","actor_username":"d_lupu@ymail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-20 19:34:52.976217+00', ''),
	('00000000-0000-0000-0000-000000000000', '3070859b-0126-4220-9029-58a1a3abe5c6', '{"action":"user_confirmation_requested","actor_id":"20d55537-6f54-41d6-98a6-474174099d17","actor_username":"carmenam_ro@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 21:37:36.168892+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f8d826e6-ca02-4ac9-a81c-c9da8ee90af8', '{"action":"user_signedup","actor_id":"20d55537-6f54-41d6-98a6-474174099d17","actor_username":"carmenam_ro@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 21:40:22.161625+00', ''),
	('00000000-0000-0000-0000-000000000000', '3dd2a6ba-6123-4bff-b22e-899dada51100', '{"action":"token_refreshed","actor_id":"82ecc83e-979b-49c3-ae81-5676f59c927c","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 23:48:43.65706+00', ''),
	('00000000-0000-0000-0000-000000000000', 'be9dda0e-a569-4c65-9816-e19b371c2de8', '{"action":"token_revoked","actor_id":"82ecc83e-979b-49c3-ae81-5676f59c927c","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-20 23:48:43.663131+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cc2f7dba-f0e9-4dce-b9bb-410c3ac6597c', '{"action":"user_confirmation_requested","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-20 23:50:00.604506+00', ''),
	('00000000-0000-0000-0000-000000000000', '9e058210-cc1c-4c08-ba61-5ed47dd35af4', '{"action":"user_signedup","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-20 23:59:40.839095+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dbb0aa50-d71d-4c62-b4d7-c9766587c2a3', '{"action":"login","actor_id":"82ecc83e-979b-49c3-ae81-5676f59c927c","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-21 00:04:21.941721+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c0e72c07-08b3-4cbd-82ea-2ef4f61b6ca7', '{"action":"logout","actor_id":"82ecc83e-979b-49c3-ae81-5676f59c927c","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-21 00:14:13.279369+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd5c603ea-34e5-4eb5-a467-bcddb9769fa0', '{"action":"user_confirmation_requested","actor_id":"cae70df8-8ff3-4f34-9d75-dae1732f24a7","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-21 00:15:22.365888+00', ''),
	('00000000-0000-0000-0000-000000000000', 'de3e05e7-80d9-4bd6-911e-dadfdd728e7b', '{"action":"user_signedup","actor_id":"cae70df8-8ff3-4f34-9d75-dae1732f24a7","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-21 00:15:39.614531+00', ''),
	('00000000-0000-0000-0000-000000000000', 'bf11b55b-2513-48ee-94f0-ab2aa1b134dd', '{"action":"login","actor_id":"cae70df8-8ff3-4f34-9d75-dae1732f24a7","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-21 02:52:13.819161+00', ''),
	('00000000-0000-0000-0000-000000000000', '5487e1fb-48b8-4c02-90a3-5b0bd76fb344', '{"action":"logout","actor_id":"cae70df8-8ff3-4f34-9d75-dae1732f24a7","actor_username":"lao.water7@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-21 03:44:58.096205+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e482b8e2-881c-4d55-be6d-7705be4a1c04', '{"action":"login","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-21 03:45:02.990732+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f38afafd-4595-4aac-a73a-2bb63132499f', '{"action":"token_refreshed","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 05:02:04.422577+00', ''),
	('00000000-0000-0000-0000-000000000000', '3fda010a-2b54-4f29-9ec3-6e0af47856db', '{"action":"token_revoked","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 05:02:04.428084+00', ''),
	('00000000-0000-0000-0000-000000000000', '2ae0616d-596e-404c-b4a3-41bfd1fcb241', '{"action":"token_refreshed","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 06:10:58.354617+00', ''),
	('00000000-0000-0000-0000-000000000000', '9976d2a1-236e-4f90-b514-f4c4b8bcccaa', '{"action":"token_revoked","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 06:10:58.358084+00', ''),
	('00000000-0000-0000-0000-000000000000', '70c91729-b6a3-4fd0-96be-3477d12e6746', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-21 06:26:47.957773+00', ''),
	('00000000-0000-0000-0000-000000000000', '204f3537-a2c3-4759-ae38-ff23bfe4b2af', '{"action":"user_signedup","actor_id":"6a70d9b5-4fb8-46f7-975b-5887fd4e47de","actor_name":"Meri Velciu","actor_username":"meri.velciu@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-21 07:26:09.534895+00', ''),
	('00000000-0000-0000-0000-000000000000', '2b3576e6-fd47-43bc-9132-f42caa11e8fe', '{"action":"token_refreshed","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 07:31:53.025573+00', ''),
	('00000000-0000-0000-0000-000000000000', 'de3821d3-4f98-4501-afc9-7f06912281c7', '{"action":"token_revoked","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 07:31:53.02915+00', ''),
	('00000000-0000-0000-0000-000000000000', '36e5982e-898f-46c7-ae9f-922c82818a86', '{"action":"logout","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-21 07:32:20.728599+00', ''),
	('00000000-0000-0000-0000-000000000000', '289f2a51-f27f-490f-9144-afe60d872da3', '{"action":"user_confirmation_requested","actor_id":"99556ce6-0304-4614-aeba-0c2f3d73a9f6","actor_username":"psiholog.kerteszreka@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-21 07:49:50.807755+00', ''),
	('00000000-0000-0000-0000-000000000000', 'bd7499c8-710c-43f0-a7f1-55a51010b273', '{"action":"user_signedup","actor_id":"99556ce6-0304-4614-aeba-0c2f3d73a9f6","actor_username":"psiholog.kerteszreka@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-21 07:50:09.546356+00', ''),
	('00000000-0000-0000-0000-000000000000', '2a58cdcb-e27f-4a6c-9647-c75a798b6ba7', '{"action":"user_confirmation_requested","actor_id":"5690ddb1-c997-4a3e-895a-06b93dab6ec4","actor_username":"pintea.daiana1399@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-21 07:52:05.117765+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e30c2ed6-d52e-4121-90a2-7976989c85b2', '{"action":"user_signedup","actor_id":"5690ddb1-c997-4a3e-895a-06b93dab6ec4","actor_username":"pintea.daiana1399@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-21 07:53:06.566467+00', ''),
	('00000000-0000-0000-0000-000000000000', '26b62eb2-13bc-4261-ac2a-bad42b8f1f94', '{"action":"user_repeated_signup","actor_id":"5690ddb1-c997-4a3e-895a-06b93dab6ec4","actor_username":"pintea.daiana1399@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-21 07:57:11.767655+00', ''),
	('00000000-0000-0000-0000-000000000000', '8a8029fe-d25a-4e9f-ba51-8103f93c00c1', '{"action":"login","actor_id":"5690ddb1-c997-4a3e-895a-06b93dab6ec4","actor_username":"pintea.daiana1399@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-21 08:02:36.997907+00', ''),
	('00000000-0000-0000-0000-000000000000', '1f19bed6-d625-4f82-b507-923607e34587', '{"action":"user_repeated_signup","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-21 08:16:13.027134+00', ''),
	('00000000-0000-0000-0000-000000000000', '4a678b78-d4be-45b3-b35a-3e451515f95e', '{"action":"user_signedup","actor_id":"4240bff7-8190-4157-bc20-1b64f6e24ca8","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-21 08:18:03.759955+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cb5e3b00-2ff4-4af5-8770-e4fe90b2d649', '{"action":"user_signedup","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-21 08:30:30.690399+00', ''),
	('00000000-0000-0000-0000-000000000000', '2aadd051-4fbb-407e-9bb6-8754fca62d33', '{"action":"token_refreshed","actor_id":"4240bff7-8190-4157-bc20-1b64f6e24ca8","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 09:58:44.855811+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b595b11a-fb72-4cd8-b9e2-d1fcf8f286a2', '{"action":"token_revoked","actor_id":"4240bff7-8190-4157-bc20-1b64f6e24ca8","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 09:58:44.861777+00', ''),
	('00000000-0000-0000-0000-000000000000', '238e8207-ce1d-4155-9c01-7ede8a71610b', '{"action":"token_refreshed","actor_id":"6a70d9b5-4fb8-46f7-975b-5887fd4e47de","actor_name":"Meri Velciu","actor_username":"meri.velciu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 10:38:22.317196+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fc32096b-beba-4e4f-8620-f3b7630e687a', '{"action":"token_revoked","actor_id":"6a70d9b5-4fb8-46f7-975b-5887fd4e47de","actor_name":"Meri Velciu","actor_username":"meri.velciu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 10:38:22.320832+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fd335ae6-97a5-45b1-b0f2-a196b87abc05', '{"action":"user_confirmation_requested","actor_id":"3b53ad8e-8faf-48c0-9628-f49ab70ded79","actor_username":"cosmo.coach.aag@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-21 10:38:35.567479+00', ''),
	('00000000-0000-0000-0000-000000000000', '0304281f-6f2e-4cc3-978e-d3b3e7c42bb1', '{"action":"user_signedup","actor_id":"3b53ad8e-8faf-48c0-9628-f49ab70ded79","actor_username":"cosmo.coach.aag@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-21 10:39:59.951842+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ae549fa7-65be-4910-aba7-7b2735ef63b3', '{"action":"user_confirmation_requested","actor_id":"e9af8519-44db-48ee-9e9d-b7fe14ccc7a5","actor_username":"izabella.cete@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-21 11:46:12.365078+00', ''),
	('00000000-0000-0000-0000-000000000000', '38f99fba-f14a-42a6-aa1e-7ce63184914f', '{"action":"user_signedup","actor_id":"e9af8519-44db-48ee-9e9d-b7fe14ccc7a5","actor_username":"izabella.cete@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-21 11:46:26.067795+00', ''),
	('00000000-0000-0000-0000-000000000000', '5a54e06b-c466-48ab-b83c-b09a61eabe1f', '{"action":"login","actor_id":"e9af8519-44db-48ee-9e9d-b7fe14ccc7a5","actor_username":"izabella.cete@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-21 11:46:55.540837+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c1d01575-8e8d-44c8-acad-aaeca9589ae6', '{"action":"token_refreshed","actor_id":"072aa24d-bfc3-4b0c-93f2-1435906d8381","actor_name":"Diana Olivia Simu","actor_username":"dianasimutm@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 11:54:11.107907+00', ''),
	('00000000-0000-0000-0000-000000000000', '3b73036a-437f-44b8-9361-e4af9e4cb96f', '{"action":"token_revoked","actor_id":"072aa24d-bfc3-4b0c-93f2-1435906d8381","actor_name":"Diana Olivia Simu","actor_username":"dianasimutm@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 11:54:11.11241+00', ''),
	('00000000-0000-0000-0000-000000000000', '98d146f6-49a4-4057-8e61-c70473fdc193', '{"action":"token_refreshed","actor_id":"dd8d0335-6696-4fb6-b186-31a0533d9587","actor_username":"adrianakarabuber79@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 12:34:06.717828+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a85c5720-5458-4c1d-aa05-8718bf524e25', '{"action":"token_revoked","actor_id":"dd8d0335-6696-4fb6-b186-31a0533d9587","actor_username":"adrianakarabuber79@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 12:34:06.720833+00', ''),
	('00000000-0000-0000-0000-000000000000', '9c245852-63f9-412a-ba6c-c6ddd14fcb56', '{"action":"token_refreshed","actor_id":"4240bff7-8190-4157-bc20-1b64f6e24ca8","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 12:40:12.255042+00', ''),
	('00000000-0000-0000-0000-000000000000', '12306faa-83f4-4fa5-97a3-c196d7f61623', '{"action":"token_revoked","actor_id":"4240bff7-8190-4157-bc20-1b64f6e24ca8","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 12:40:12.258157+00', ''),
	('00000000-0000-0000-0000-000000000000', '9ebcbb5e-db57-426b-aea7-27ce8e28dd4a', '{"action":"logout","actor_id":"4240bff7-8190-4157-bc20-1b64f6e24ca8","actor_name":"hellosuciaghi","actor_username":"hellosuciaghi@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-21 12:40:17.195246+00', ''),
	('00000000-0000-0000-0000-000000000000', '180a8715-f213-465d-83e5-71261daa0dd0', '{"action":"token_refreshed","actor_id":"6a70d9b5-4fb8-46f7-975b-5887fd4e47de","actor_name":"Meri Velciu","actor_username":"meri.velciu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 13:04:14.700737+00', ''),
	('00000000-0000-0000-0000-000000000000', '4ee54c24-1248-49c8-9ad9-5479db1f4d3a', '{"action":"token_revoked","actor_id":"6a70d9b5-4fb8-46f7-975b-5887fd4e47de","actor_name":"Meri Velciu","actor_username":"meri.velciu@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 13:04:14.704237+00', ''),
	('00000000-0000-0000-0000-000000000000', '2a599089-7124-4789-9219-a6ee485f89a7', '{"action":"token_refreshed","actor_id":"99556ce6-0304-4614-aeba-0c2f3d73a9f6","actor_username":"psiholog.kerteszreka@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 13:50:24.538085+00', ''),
	('00000000-0000-0000-0000-000000000000', '4374be5a-890e-4a18-ade9-15f263027be5', '{"action":"token_revoked","actor_id":"99556ce6-0304-4614-aeba-0c2f3d73a9f6","actor_username":"psiholog.kerteszreka@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 13:50:24.541925+00', ''),
	('00000000-0000-0000-0000-000000000000', '46dd4ed7-9a16-4b49-86de-08abd64a9d04', '{"action":"user_confirmation_requested","actor_id":"a3c141d5-a60e-4211-99ce-d1828f4174cf","actor_username":"ggabicoz@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-21 14:01:50.266329+00', ''),
	('00000000-0000-0000-0000-000000000000', '3c8f27ac-f5e3-4e3c-b99f-84a69b8b4705', '{"action":"user_signedup","actor_id":"a3c141d5-a60e-4211-99ce-d1828f4174cf","actor_username":"ggabicoz@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-21 14:02:20.434465+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e3ff3fb6-dabe-4332-9bac-720d417fd742', '{"action":"login","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-21 15:26:30.665918+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b69fe84d-f559-452a-a39c-33ee8cc84b12', '{"action":"login","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-21 15:29:45.14851+00', ''),
	('00000000-0000-0000-0000-000000000000', '6908d897-076d-44a2-afbc-a61365285ea8', '{"action":"logout","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-21 15:43:04.81454+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c1591c04-600f-47d1-80ab-e33edd8ebf6a', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-21 15:43:25.720713+00', ''),
	('00000000-0000-0000-0000-000000000000', '992b991e-e0dd-404a-8cc8-89c63ff2cb6c', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-21 15:43:58.441868+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b25c2a37-b6db-4d26-a478-a75657b972fc', '{"action":"login","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-21 15:44:05.394508+00', ''),
	('00000000-0000-0000-0000-000000000000', '611047a3-dc2f-4b3f-ae0d-aa6b4a3a0572', '{"action":"token_refreshed","actor_id":"20d55537-6f54-41d6-98a6-474174099d17","actor_username":"carmenam_ro@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 15:59:27.718596+00', ''),
	('00000000-0000-0000-0000-000000000000', '5dab218d-acd1-443f-b2de-dcc130f7b693', '{"action":"token_revoked","actor_id":"20d55537-6f54-41d6-98a6-474174099d17","actor_username":"carmenam_ro@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 15:59:27.721378+00', ''),
	('00000000-0000-0000-0000-000000000000', '022fff14-4ea3-4091-a494-34d3c0e83d0f', '{"action":"token_refreshed","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 16:49:51.492577+00', ''),
	('00000000-0000-0000-0000-000000000000', '36f195b8-c79f-4dd8-9159-ace7dbebe8ad', '{"action":"token_revoked","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 16:49:51.504099+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ac926b19-336a-423c-aeff-e93e829a7430', '{"action":"token_refreshed","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 16:49:53.224993+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c3795cc8-1aa5-4629-9346-6d676b5149be', '{"action":"token_refreshed","actor_id":"3e6b8532-e559-4bba-a913-9178fdb2a0bd","actor_name":"Sorina Brif","actor_username":"brifsorina@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 17:19:42.654094+00', ''),
	('00000000-0000-0000-0000-000000000000', '1651e17a-f216-45d3-96e5-64b1102f431c', '{"action":"token_revoked","actor_id":"3e6b8532-e559-4bba-a913-9178fdb2a0bd","actor_name":"Sorina Brif","actor_username":"brifsorina@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 17:19:42.658944+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e38da777-d53f-4b3c-8c07-4e7fccd3d4e5', '{"action":"token_refreshed","actor_id":"3b53ad8e-8faf-48c0-9628-f49ab70ded79","actor_username":"cosmo.coach.aag@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 19:10:42.906924+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e1eb9419-3da5-4c40-9356-64c317c00b5d', '{"action":"token_revoked","actor_id":"3b53ad8e-8faf-48c0-9628-f49ab70ded79","actor_username":"cosmo.coach.aag@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-21 19:10:42.912243+00', ''),
	('00000000-0000-0000-0000-000000000000', '78607f2e-d768-488e-aefb-1b51f7a84004', '{"action":"login","actor_id":"ae26134b-38c8-4748-8770-5b73d79cae08","actor_username":"teomury@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-21 20:19:14.924509+00', ''),
	('00000000-0000-0000-0000-000000000000', '085418ce-a492-49d7-9085-3fba8359887f', '{"action":"token_refreshed","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 01:54:56.112426+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e838a609-c0fb-4722-a87e-00904dbf0f1e', '{"action":"token_revoked","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 01:54:56.119233+00', ''),
	('00000000-0000-0000-0000-000000000000', '53dfa230-9414-4302-9d28-83fab47e15e1', '{"action":"token_refreshed","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 03:14:33.56285+00', ''),
	('00000000-0000-0000-0000-000000000000', '39ba0ec9-57c0-4ebd-9e0a-dcb7e5540129', '{"action":"token_revoked","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 03:14:33.56499+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a0816001-1be2-4e07-a26c-b055c877ba69', '{"action":"token_refreshed","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 05:35:08.906766+00', ''),
	('00000000-0000-0000-0000-000000000000', '7aa25935-d206-402e-a7e5-e449ea50e90d', '{"action":"token_revoked","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 05:35:08.910588+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c5ced9a2-ef3d-479a-86ef-40ff6641b65a', '{"action":"token_refreshed","actor_id":"8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8","actor_username":"adryma2016@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 05:39:11.873778+00', ''),
	('00000000-0000-0000-0000-000000000000', '30a2e389-d0ba-4f8e-8d18-7d0754e7e0e2', '{"action":"token_revoked","actor_id":"8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8","actor_username":"adryma2016@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 05:39:11.875906+00', ''),
	('00000000-0000-0000-0000-000000000000', '0ea25d1f-49c6-4a42-aea4-a5bafa210119', '{"action":"token_refreshed","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 06:37:12.054519+00', ''),
	('00000000-0000-0000-0000-000000000000', '8b3eea40-0954-4efd-b5d3-1e4cfcb790c5', '{"action":"token_revoked","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 06:37:12.062042+00', ''),
	('00000000-0000-0000-0000-000000000000', '20e354a6-ad15-4626-8bcb-744427f5e03a', '{"action":"user_signedup","actor_id":"98daacc7-a021-4869-b7d3-33599178f966","actor_name":"Laura Mera","actor_username":"laura.mera1128@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-22 06:54:03.059007+00', ''),
	('00000000-0000-0000-0000-000000000000', '41b07b06-b302-4114-b150-1ef1a62e6b47', '{"action":"token_refreshed","actor_id":"ae26134b-38c8-4748-8770-5b73d79cae08","actor_username":"teomury@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 07:15:21.210555+00', ''),
	('00000000-0000-0000-0000-000000000000', '01e7da2d-c18d-4702-a94b-b9f39b8285e0', '{"action":"token_revoked","actor_id":"ae26134b-38c8-4748-8770-5b73d79cae08","actor_username":"teomury@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 07:15:21.213651+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd2457848-a123-4266-ad3d-ed3875a44bde', '{"action":"token_refreshed","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 07:37:25.252714+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c0c29c61-95cc-47a6-bf7e-d28179b6819e', '{"action":"token_revoked","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 07:37:25.256711+00', ''),
	('00000000-0000-0000-0000-000000000000', '0cfc74a0-e886-4371-b5bb-df1e1a6b9640', '{"action":"logout","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-22 07:37:40.263384+00', ''),
	('00000000-0000-0000-0000-000000000000', '8c866ae9-6fb0-43cc-9a5c-25030402f52a', '{"action":"login","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-22 07:37:46.881196+00', ''),
	('00000000-0000-0000-0000-000000000000', '8bad05f9-daa5-4838-b612-2cf8bc6e556c', '{"action":"user_confirmation_requested","actor_id":"65da1664-c0da-4c49-88c8-dce05acc1374","actor_username":"hey_anamaria@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-22 07:43:06.946303+00', ''),
	('00000000-0000-0000-0000-000000000000', '3b4853a6-5749-4c26-9ef4-ed2ae3f4c436', '{"action":"user_signedup","actor_id":"65da1664-c0da-4c49-88c8-dce05acc1374","actor_username":"hey_anamaria@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-22 07:43:42.373383+00', ''),
	('00000000-0000-0000-0000-000000000000', '84f30aa5-ac49-4a17-8d97-c5444a5938cf', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-22 08:48:58.394853+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fa81bf24-b8cc-4b6b-b57a-232b7e3ee452', '{"action":"logout","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-22 08:51:12.364091+00', ''),
	('00000000-0000-0000-0000-000000000000', '4053210f-7905-4489-b224-1fec65e6c8fc', '{"action":"token_refreshed","actor_id":"65da1664-c0da-4c49-88c8-dce05acc1374","actor_username":"hey_anamaria@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 09:10:14.708267+00', ''),
	('00000000-0000-0000-0000-000000000000', '733ae97b-b802-4d9b-ac26-b8fc583c10e3', '{"action":"token_revoked","actor_id":"65da1664-c0da-4c49-88c8-dce05acc1374","actor_username":"hey_anamaria@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 09:10:14.709881+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cb728313-c4f8-42b6-aa33-5f38f30f2f58', '{"action":"token_refreshed","actor_id":"8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8","actor_username":"adryma2016@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 10:10:49.672302+00', ''),
	('00000000-0000-0000-0000-000000000000', '66ec246e-9133-4c68-beb5-5512787dd512', '{"action":"token_revoked","actor_id":"8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8","actor_username":"adryma2016@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 10:10:49.675531+00', ''),
	('00000000-0000-0000-0000-000000000000', '10fa4c2e-0c50-4a3c-b737-7da46b2d3c84', '{"action":"token_refreshed","actor_id":"65da1664-c0da-4c49-88c8-dce05acc1374","actor_username":"hey_anamaria@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 10:10:55.663713+00', ''),
	('00000000-0000-0000-0000-000000000000', '095c4f6a-6546-4382-9dac-14ea152d4cc4', '{"action":"token_revoked","actor_id":"65da1664-c0da-4c49-88c8-dce05acc1374","actor_username":"hey_anamaria@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 10:10:55.665181+00', ''),
	('00000000-0000-0000-0000-000000000000', '97f10486-470c-4899-a8a6-f65fe921357a', '{"action":"token_refreshed","actor_id":"65da1664-c0da-4c49-88c8-dce05acc1374","actor_username":"hey_anamaria@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 11:09:37.755191+00', ''),
	('00000000-0000-0000-0000-000000000000', '9fa91dd5-4086-490c-a5fe-8b09fddaf030', '{"action":"token_revoked","actor_id":"65da1664-c0da-4c49-88c8-dce05acc1374","actor_username":"hey_anamaria@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 11:09:37.761545+00', ''),
	('00000000-0000-0000-0000-000000000000', '23447254-04e5-4445-b8b3-351a57ae6c8b', '{"action":"token_refreshed","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 11:23:34.997928+00', ''),
	('00000000-0000-0000-0000-000000000000', '0c602750-48a1-4eaf-af8c-7265a171ec3f', '{"action":"token_revoked","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 11:23:35.009315+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b3630db3-3a3e-4c39-ac38-5654ea824a63', '{"action":"token_refreshed","actor_id":"ae26134b-38c8-4748-8770-5b73d79cae08","actor_username":"teomury@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 11:26:18.05226+00', ''),
	('00000000-0000-0000-0000-000000000000', '29e5a1cb-d43d-4480-bdeb-1ab1af0b7072', '{"action":"token_revoked","actor_id":"ae26134b-38c8-4748-8770-5b73d79cae08","actor_username":"teomury@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 11:26:18.055035+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ac1c41a7-9f21-44fd-b71b-4c0916e0356c', '{"action":"token_refreshed","actor_id":"d707eee8-8de6-49fa-a4a6-00d79d6eded8","actor_username":"camelya98@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 11:41:23.037077+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cce462fb-10a6-4985-8d6a-29c557841a22', '{"action":"token_revoked","actor_id":"d707eee8-8de6-49fa-a4a6-00d79d6eded8","actor_username":"camelya98@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 11:41:23.040115+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a511f5c2-1d63-476f-9fab-c2a9bb078a15', '{"action":"user_confirmation_requested","actor_id":"1f149689-c4dc-412f-8de6-9b25ee804842","actor_username":"nutzy_neiconi@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-22 12:43:42.45874+00', ''),
	('00000000-0000-0000-0000-000000000000', '077e9f71-179e-4c0a-8a99-05b69072d39d', '{"action":"user_signedup","actor_id":"1f149689-c4dc-412f-8de6-9b25ee804842","actor_username":"nutzy_neiconi@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-22 12:44:52.503885+00', ''),
	('00000000-0000-0000-0000-000000000000', 'fbee8bb8-abe8-4d9d-970a-87245071f1b5', '{"action":"login","actor_id":"1f149689-c4dc-412f-8de6-9b25ee804842","actor_username":"nutzy_neiconi@yahoo.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-22 12:45:50.124319+00', ''),
	('00000000-0000-0000-0000-000000000000', '51e33c41-2361-4964-bf47-320663631b67', '{"action":"user_signedup","actor_id":"398915d4-fa9b-430f-acd0-c44c6197221b","actor_name":"Adriana - Mindful Psychology","actor_username":"adrianamindful@gmail.com","actor_via_sso":false,"log_type":"team","traits":{"provider":"google"}}', '2025-05-22 12:56:47.024162+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a1357271-edfc-4489-9fc5-96adb085acec', '{"action":"logout","actor_id":"1f149689-c4dc-412f-8de6-9b25ee804842","actor_username":"nutzy_neiconi@yahoo.com","actor_via_sso":false,"log_type":"account"}', '2025-05-22 13:07:08.748302+00', ''),
	('00000000-0000-0000-0000-000000000000', '253e9384-4ee6-4662-b5b9-b408b08d7f9f', '{"action":"login","actor_id":"1f149689-c4dc-412f-8de6-9b25ee804842","actor_username":"nutzy_neiconi@yahoo.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-22 13:07:33.928081+00', ''),
	('00000000-0000-0000-0000-000000000000', '31807a38-c8d8-40b2-8c09-946b1087de58', '{"action":"token_refreshed","actor_id":"8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8","actor_username":"adryma2016@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 13:20:04.87672+00', ''),
	('00000000-0000-0000-0000-000000000000', '9cbbb9d1-c83b-4bba-a148-c1970e9231c7', '{"action":"token_revoked","actor_id":"8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8","actor_username":"adryma2016@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 13:20:04.879076+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b6d7c796-8697-42bc-931e-8ca60610c512', '{"action":"token_refreshed","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 13:21:57.110682+00', ''),
	('00000000-0000-0000-0000-000000000000', 'db81fd12-8006-41c4-8a80-766ce5695d0c', '{"action":"token_revoked","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 13:21:57.111519+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c519ae74-1302-44a4-9735-4bee2dc93fca', '{"action":"login","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-22 13:25:41.108049+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd9d5fc43-c563-41bd-b68e-0bf88fbf84d7', '{"action":"user_confirmation_requested","actor_id":"1bd491bf-3874-47d1-a4ed-0983f63a866e","actor_username":"terapeutholistic.eliseiadam@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-22 13:26:55.57106+00', ''),
	('00000000-0000-0000-0000-000000000000', '16af7fa9-58ff-423e-b455-894ed1d88da0', '{"action":"user_signedup","actor_id":"1bd491bf-3874-47d1-a4ed-0983f63a866e","actor_username":"terapeutholistic.eliseiadam@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-22 13:28:23.479804+00', ''),
	('00000000-0000-0000-0000-000000000000', '6660727c-5ad5-4f40-a375-bb572417bbbb', '{"action":"login","actor_id":"1bd491bf-3874-47d1-a4ed-0983f63a866e","actor_username":"terapeutholistic.eliseiadam@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-22 13:37:19.091924+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ac930a5b-765c-461e-a3ed-74d94b3efae4', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-22 13:39:15.116869+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c65318b5-5c60-4b2c-8505-2ad8f7ea78fe', '{"action":"token_refreshed","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 13:41:56.724676+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd6465a31-e103-4072-92bc-9d0ef6cfd5b2', '{"action":"token_revoked","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 13:41:56.72913+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b347ada2-0486-49d3-930d-e1429e868fa9', '{"action":"user_confirmation_requested","actor_id":"147fcc1b-10f1-4184-9d95-d09505d736fa","actor_username":"ionutrus231@gmail.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-22 13:45:54.478208+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ef1bcb98-e4bd-4548-91b6-6fceefc22b2f', '{"action":"user_signedup","actor_id":"147fcc1b-10f1-4184-9d95-d09505d736fa","actor_username":"ionutrus231@gmail.com","actor_via_sso":false,"log_type":"team"}', '2025-05-22 13:46:40.989389+00', ''),
	('00000000-0000-0000-0000-000000000000', '506e85bf-680f-466c-bed8-e4f6e35df7c7', '{"action":"user_confirmation_requested","actor_id":"8458bab3-1fb1-4eb7-8cad-f555bc58fc8f","actor_username":"sandu_elena1998@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-22 14:37:27.34874+00', ''),
	('00000000-0000-0000-0000-000000000000', '80c7639d-7dd4-474b-a4b1-3c9156c6f659', '{"action":"user_signedup","actor_id":"8458bab3-1fb1-4eb7-8cad-f555bc58fc8f","actor_username":"sandu_elena1998@yahoo.com","actor_via_sso":false,"log_type":"team"}', '2025-05-22 14:37:53.967272+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a73dc79e-6594-4310-bffe-7ce12ceb8fd5', '{"action":"token_refreshed","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 14:48:50.587055+00', ''),
	('00000000-0000-0000-0000-000000000000', '7f5681c9-f8be-4200-b44c-e43bda829297', '{"action":"token_revoked","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 14:48:50.589414+00', ''),
	('00000000-0000-0000-0000-000000000000', '8f38d252-a4f2-4442-9bac-8d6e87362d04', '{"action":"token_refreshed","actor_id":"1bd491bf-3874-47d1-a4ed-0983f63a866e","actor_username":"terapeutholistic.eliseiadam@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 14:54:15.584601+00', ''),
	('00000000-0000-0000-0000-000000000000', '1cc937d8-1e6f-4b9f-b336-72c1685361b5', '{"action":"token_revoked","actor_id":"1bd491bf-3874-47d1-a4ed-0983f63a866e","actor_username":"terapeutholistic.eliseiadam@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 14:54:15.587645+00', ''),
	('00000000-0000-0000-0000-000000000000', '007867d0-3207-4a4f-95e6-1aa521932bd3', '{"action":"user_confirmation_requested","actor_id":"de7ba501-a94e-4f86-81b3-0afe662ae8de","actor_username":"dan.magirescu@innercoach.ro","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-22 14:55:46.402229+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f5929ce5-5f10-4107-88a5-d02cd3857475', '{"action":"user_signedup","actor_id":"de7ba501-a94e-4f86-81b3-0afe662ae8de","actor_username":"dan.magirescu@innercoach.ro","actor_via_sso":false,"log_type":"team"}', '2025-05-22 14:56:08.862293+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd616d2f6-994a-4c98-b0e7-291098892285', '{"action":"login","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-22 15:19:58.054182+00', ''),
	('00000000-0000-0000-0000-000000000000', '65b15268-ead7-4001-82d1-4bb28c4e61a1', '{"action":"logout","actor_id":"3a317800-976d-4277-a491-27d7962bb16b","actor_name":"Alexandru Suciaghi","actor_username":"suciaghialex@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-22 15:20:33.472393+00', ''),
	('00000000-0000-0000-0000-000000000000', '293862e8-5307-41b5-bda9-e1aefccbba64', '{"action":"login","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"google"}}', '2025-05-22 15:20:40.552915+00', ''),
	('00000000-0000-0000-0000-000000000000', '548883bd-fcbe-445b-a4c4-bbe0638eda8c', '{"action":"logout","actor_id":"4b6f4102-c588-406c-a091-79dd2485fb81","actor_name":"Suciaghi Alexandru","actor_username":"suciaghi97@gmail.com","actor_via_sso":false,"log_type":"account"}', '2025-05-22 15:21:49.905613+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c13fd519-b468-47de-bab8-ef9462988c72', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 15:42:11.44252+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f0ca4a35-fb3d-4718-9c58-12652e97a552', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 15:42:11.450077+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b7fbc27a-4a8f-4f15-adb8-3322f0b8cce3', '{"action":"token_refreshed","actor_id":"de7ba501-a94e-4f86-81b3-0afe662ae8de","actor_username":"dan.magirescu@innercoach.ro","actor_via_sso":false,"log_type":"token"}', '2025-05-22 16:11:02.75192+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e846ee68-e962-4969-8c81-282878f0990c', '{"action":"token_revoked","actor_id":"de7ba501-a94e-4f86-81b3-0afe662ae8de","actor_username":"dan.magirescu@innercoach.ro","actor_via_sso":false,"log_type":"token"}', '2025-05-22 16:11:02.757689+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b66bc913-8794-42c7-8562-287974f78df7', '{"action":"token_refreshed","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 16:43:18.9075+00', ''),
	('00000000-0000-0000-0000-000000000000', '8c0b57a6-5c55-457d-a21f-fdb49645971c', '{"action":"token_revoked","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 16:43:18.910521+00', ''),
	('00000000-0000-0000-0000-000000000000', '75eff39c-2ffc-45a9-8fee-f9dd980da241', '{"action":"token_refreshed","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 18:09:14.276168+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c3f98aee-cb09-4947-a650-63cb5889db26', '{"action":"token_revoked","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 18:09:14.279801+00', ''),
	('00000000-0000-0000-0000-000000000000', '2e45930a-2b02-4c86-9069-104669bcf475', '{"action":"token_refreshed","actor_id":"de7ba501-a94e-4f86-81b3-0afe662ae8de","actor_username":"dan.magirescu@innercoach.ro","actor_via_sso":false,"log_type":"token"}', '2025-05-22 18:32:36.120406+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c047c4b4-35d4-4e71-b874-6ea8d02290f9', '{"action":"token_revoked","actor_id":"de7ba501-a94e-4f86-81b3-0afe662ae8de","actor_username":"dan.magirescu@innercoach.ro","actor_via_sso":false,"log_type":"token"}', '2025-05-22 18:32:36.124704+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a8387eea-43ce-4d93-82c4-cc4f84898d64', '{"action":"token_refreshed","actor_id":"398915d4-fa9b-430f-acd0-c44c6197221b","actor_name":"Adriana - Mindful Psychology","actor_username":"adrianamindful@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 18:35:11.445072+00', ''),
	('00000000-0000-0000-0000-000000000000', '14432897-7944-4fb7-b1ab-b2f6eec91d45', '{"action":"token_revoked","actor_id":"398915d4-fa9b-430f-acd0-c44c6197221b","actor_name":"Adriana - Mindful Psychology","actor_username":"adrianamindful@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 18:35:11.448123+00', ''),
	('00000000-0000-0000-0000-000000000000', '4c51e4ab-0191-40d9-b2a9-6e0a18db764e', '{"action":"token_refreshed","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 19:18:08.350647+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd52eb9ad-83e0-4deb-95c5-1a92caeb73dd', '{"action":"token_revoked","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 19:18:08.353408+00', ''),
	('00000000-0000-0000-0000-000000000000', '8cce5b1d-1666-481f-ae0f-3d030cca6ad2', '{"action":"token_refreshed","actor_id":"147fcc1b-10f1-4184-9d95-d09505d736fa","actor_username":"ionutrus231@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 20:40:51.577678+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c3d8f4a5-196a-4a6c-bd92-adce44335741', '{"action":"token_revoked","actor_id":"147fcc1b-10f1-4184-9d95-d09505d736fa","actor_username":"ionutrus231@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 20:40:51.582174+00', ''),
	('00000000-0000-0000-0000-000000000000', '5930d6c5-d429-494c-b3f2-18b65e16dd87', '{"action":"token_refreshed","actor_id":"20d55537-6f54-41d6-98a6-474174099d17","actor_username":"carmenam_ro@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 20:43:03.271827+00', ''),
	('00000000-0000-0000-0000-000000000000', '7481df97-9324-4daf-baca-29a598452b98', '{"action":"token_revoked","actor_id":"20d55537-6f54-41d6-98a6-474174099d17","actor_username":"carmenam_ro@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 20:43:03.273929+00', ''),
	('00000000-0000-0000-0000-000000000000', '84e46be6-5962-4a4c-9c73-ffd7e138f6b6', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 21:10:04.10156+00', ''),
	('00000000-0000-0000-0000-000000000000', '90d7305d-af71-401e-9d3a-88ca397f81fe', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 21:10:04.105431+00', ''),
	('00000000-0000-0000-0000-000000000000', 'cc1245bb-eff4-46e1-8cd8-82bf76f63349', '{"action":"token_refreshed","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 21:33:40.492448+00', ''),
	('00000000-0000-0000-0000-000000000000', '038434d4-41aa-4352-a9fe-7a943f6078c4', '{"action":"token_revoked","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 21:33:40.495296+00', ''),
	('00000000-0000-0000-0000-000000000000', '8b3a4ae2-d913-487a-b5fa-37238389ce32', '{"action":"token_refreshed","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 21:36:42.146495+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e4786a85-b6c4-478d-b23b-01e07e90c125', '{"action":"token_revoked","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 21:36:42.149595+00', ''),
	('00000000-0000-0000-0000-000000000000', '673f1e9a-0b3e-488f-a8f4-00526f7ca3d6', '{"action":"token_refreshed","actor_id":"398915d4-fa9b-430f-acd0-c44c6197221b","actor_name":"Adriana - Mindful Psychology","actor_username":"adrianamindful@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 22:08:59.589746+00', ''),
	('00000000-0000-0000-0000-000000000000', '2631b8d3-438c-4bd0-8726-5bf029c99b5c', '{"action":"token_revoked","actor_id":"398915d4-fa9b-430f-acd0-c44c6197221b","actor_name":"Adriana - Mindful Psychology","actor_username":"adrianamindful@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 22:08:59.596017+00', ''),
	('00000000-0000-0000-0000-000000000000', '51ca4426-9ce8-4329-a9f9-d8c5d42e6aa0', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 22:08:59.868686+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b428c8f0-a485-41fa-99fa-a95dd9c3956a', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-22 22:08:59.869324+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e251b9c1-77bf-4f1a-8e6f-313ca326ac2c', '{"action":"user_confirmation_requested","actor_id":"52514d39-b9bc-42e3-8a24-69cd971a8414","actor_username":"carmenrauta68@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-23 01:29:56.060245+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f5033f9e-76d1-46ae-986b-e35590718eaf', '{"action":"token_refreshed","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 03:15:54.447288+00', ''),
	('00000000-0000-0000-0000-000000000000', '4cfa6469-a99b-4972-9688-b401827508a4', '{"action":"token_revoked","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 03:15:54.462999+00', ''),
	('00000000-0000-0000-0000-000000000000', '28140e80-b867-4344-8422-820fb8c7d54a', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 03:26:05.514335+00', ''),
	('00000000-0000-0000-0000-000000000000', '9f529e62-7bc6-486b-920f-7773164ef133', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 03:26:05.519164+00', ''),
	('00000000-0000-0000-0000-000000000000', 'db4b7081-92ea-4b81-a2e9-caa1311b9c27', '{"action":"user_confirmation_requested","actor_id":"52514d39-b9bc-42e3-8a24-69cd971a8414","actor_username":"carmenrauta68@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-23 03:56:49.685246+00', ''),
	('00000000-0000-0000-0000-000000000000', '1c66f207-f068-4918-965e-9d404314dbc4', '{"action":"user_confirmation_requested","actor_id":"52514d39-b9bc-42e3-8a24-69cd971a8414","actor_username":"carmenrauta68@yahoo.com","actor_via_sso":false,"log_type":"user","traits":{"provider":"email"}}', '2025-05-23 04:43:17.500324+00', ''),
	('00000000-0000-0000-0000-000000000000', '1acca3ab-e06b-4f71-9704-28033f87aeb8', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 05:05:07.492653+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e12e4ff2-75a0-41ea-94b0-4dfc9a46151e', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 05:05:07.49518+00', ''),
	('00000000-0000-0000-0000-000000000000', '3acb1661-8b70-417a-ad58-1c40b3590762', '{"action":"token_refreshed","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 05:09:14.014514+00', ''),
	('00000000-0000-0000-0000-000000000000', '97e9a015-ee5a-4428-aee4-2cc4fba8b394', '{"action":"token_revoked","actor_id":"1e8e19fd-7346-4d83-807e-404c01903baf","actor_username":"baciu.raul555@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 05:09:14.016433+00', ''),
	('00000000-0000-0000-0000-000000000000', 'dfcf9b5a-c68d-4528-9265-aa9cab6e954c', '{"action":"login","actor_id":"147fcc1b-10f1-4184-9d95-d09505d736fa","actor_username":"ionutrus231@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-23 05:47:00.870635+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a3636ee1-38fc-4500-af11-5170133e1117', '{"action":"token_refreshed","actor_id":"682d23b2-3bb3-4f55-9f23-5b7689983e82","actor_username":"alexandra.pandelea88@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 06:41:38.889178+00', ''),
	('00000000-0000-0000-0000-000000000000', 'b30d822a-d80f-4434-8777-f570fb6a1e19', '{"action":"token_revoked","actor_id":"682d23b2-3bb3-4f55-9f23-5b7689983e82","actor_username":"alexandra.pandelea88@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 06:41:38.89335+00', ''),
	('00000000-0000-0000-0000-000000000000', 'c193d929-e83a-46e8-9a26-3fae91272350', '{"action":"token_refreshed","actor_id":"d3275dfe-f4df-44fc-acaa-659e92369e66","actor_username":"danutjilavu@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 07:06:08.101458+00', ''),
	('00000000-0000-0000-0000-000000000000', '72bbea50-0400-4f88-894c-7e0a3dfc4e33', '{"action":"token_revoked","actor_id":"d3275dfe-f4df-44fc-acaa-659e92369e66","actor_username":"danutjilavu@yahoo.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 07:06:08.10855+00', ''),
	('00000000-0000-0000-0000-000000000000', '4e42e222-72de-4eb8-bb46-558d64e0be34', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 07:32:56.460759+00', ''),
	('00000000-0000-0000-0000-000000000000', 'f2d09e7a-3af7-4543-9468-eba5821c5039', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 07:32:56.467986+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a2e494ae-504b-4683-a2ef-8f9debe7811b', '{"action":"token_refreshed","actor_id":"ae26134b-38c8-4748-8770-5b73d79cae08","actor_username":"teomury@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 08:01:22.439904+00', ''),
	('00000000-0000-0000-0000-000000000000', '1526f082-4350-44c5-a56a-6b9e6115d3d6', '{"action":"token_revoked","actor_id":"ae26134b-38c8-4748-8770-5b73d79cae08","actor_username":"teomury@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 08:01:22.443668+00', ''),
	('00000000-0000-0000-0000-000000000000', '4ac67a37-bff1-4ec0-9c5a-89241a3e3762', '{"action":"token_refreshed","actor_id":"1bd491bf-3874-47d1-a4ed-0983f63a866e","actor_username":"terapeutholistic.eliseiadam@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 09:22:26.08737+00', ''),
	('00000000-0000-0000-0000-000000000000', '1a665d28-06e3-448f-9d07-4a80d2adc5a1', '{"action":"token_revoked","actor_id":"1bd491bf-3874-47d1-a4ed-0983f63a866e","actor_username":"terapeutholistic.eliseiadam@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 09:22:26.095517+00', ''),
	('00000000-0000-0000-0000-000000000000', '0bf26196-2cea-4584-862c-0bd0258f7a58', '{"action":"token_refreshed","actor_id":"1bd491bf-3874-47d1-a4ed-0983f63a866e","actor_username":"terapeutholistic.eliseiadam@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 10:23:16.992843+00', ''),
	('00000000-0000-0000-0000-000000000000', '91e12d56-31d6-4026-a591-90a5ba99d77c', '{"action":"token_revoked","actor_id":"1bd491bf-3874-47d1-a4ed-0983f63a866e","actor_username":"terapeutholistic.eliseiadam@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 10:23:16.998039+00', ''),
	('00000000-0000-0000-0000-000000000000', '0dad3353-fda2-408d-b329-c554d970c7ad', '{"action":"login","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-23 11:22:13.031367+00', ''),
	('00000000-0000-0000-0000-000000000000', 'a54bf938-34bf-4a2d-b9b3-0b1b1bb3c728', '{"action":"token_refreshed","actor_id":"1bd491bf-3874-47d1-a4ed-0983f63a866e","actor_username":"terapeutholistic.eliseiadam@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 11:33:56.334246+00', ''),
	('00000000-0000-0000-0000-000000000000', '0aed461a-3f93-415c-84b2-ab0f30eb3b79', '{"action":"token_revoked","actor_id":"1bd491bf-3874-47d1-a4ed-0983f63a866e","actor_username":"terapeutholistic.eliseiadam@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 11:33:56.337431+00', ''),
	('00000000-0000-0000-0000-000000000000', 'e1e35d00-7e86-4d1a-bfa3-7e4c8ebe0343', '{"action":"login","actor_id":"de7ba501-a94e-4f86-81b3-0afe662ae8de","actor_username":"dan.magirescu@innercoach.ro","actor_via_sso":false,"log_type":"account","traits":{"provider":"email"}}', '2025-05-23 11:39:41.107419+00', ''),
	('00000000-0000-0000-0000-000000000000', 'ff58d2ab-e013-42c0-a5b4-459b4b3c1dfb', '{"action":"token_refreshed","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 12:45:40.090324+00', ''),
	('00000000-0000-0000-0000-000000000000', '6b31f194-5485-4fee-b97d-306aee4a6433', '{"action":"token_revoked","actor_id":"e2479383-7ba2-4290-beb7-6e8d08b52ee6","actor_username":"sory.loby@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 12:45:40.099395+00', ''),
	('00000000-0000-0000-0000-000000000000', '1b139356-d446-4584-9d81-04c8b71f2497', '{"action":"token_refreshed","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 12:54:36.320622+00', ''),
	('00000000-0000-0000-0000-000000000000', 'd05f86de-62dd-4673-9b06-c7151f06bd62', '{"action":"token_revoked","actor_id":"30afa3ac-3cac-4756-a1dc-3f9a2ae8d370","actor_name":"Melinda Havadi","actor_username":"meli.havadi@gmail.com","actor_via_sso":false,"log_type":"token"}', '2025-05-23 12:54:36.324574+00', '');


--
-- Data for Name: flow_state; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: users; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

INSERT INTO "auth"."users" ("instance_id", "id", "aud", "role", "email", "encrypted_password", "email_confirmed_at", "invited_at", "confirmation_token", "confirmation_sent_at", "recovery_token", "recovery_sent_at", "email_change_token_new", "email_change", "email_change_sent_at", "last_sign_in_at", "raw_app_meta_data", "raw_user_meta_data", "is_super_admin", "created_at", "updated_at", "phone", "phone_confirmed_at", "phone_change", "phone_change_token", "phone_change_sent_at", "email_change_token_current", "email_change_confirm_status", "banned_until", "reauthentication_token", "reauthentication_sent_at", "is_sso_user", "deleted_at", "is_anonymous") VALUES
	('00000000-0000-0000-0000-000000000000', '65da1664-c0da-4c49-88c8-dce05acc1374', 'authenticated', 'authenticated', 'hey_anamaria@yahoo.com', '$2a$10$LmlpWkPIqHx2cuXChVCIF.H/9K3yakewfU5q2bPbXvcx4ZZ6GNvxS', '2025-05-22 07:43:42.374037+00', NULL, '', '2025-05-22 07:43:06.949401+00', '', NULL, '', '', NULL, '2025-05-22 07:43:42.384015+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "65da1664-c0da-4c49-88c8-dce05acc1374", "email": "hey_anamaria@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-19 14:09:03.689477+00', '2025-05-22 11:09:37.770235+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'f9a83a83-6324-46d1-9e75-3eddf8edd890', 'authenticated', 'authenticated', 'anghelescucodrutvictor@gmail.com', '$2a$10$jvvVMTbpqd09FM7Y6QToz.G/Kiq4FkssD4EhIHB7oAMb4AHiRoo6i', '2025-05-15 13:48:19.407512+00', NULL, '', '2025-05-15 13:48:04.892843+00', '', NULL, '', '', NULL, '2025-05-15 13:48:19.410768+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "f9a83a83-6324-46d1-9e75-3eddf8edd890", "email": "anghelescucodrutvictor@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-15 13:48:04.871889+00', '2025-05-17 07:10:28.109747+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '1d4e4d74-493a-4758-a5e1-3229a81bae5d', 'authenticated', 'authenticated', 'inna.medeea.lupu@gmail.com', '$2a$10$CZOHq0bJp768gWdYJHcOI.SOJWyT3DioBT9qHbiNqhLrRBiercU/e', '2025-05-15 08:09:35.080717+00', NULL, '', '2025-05-15 08:07:38.522192+00', '', NULL, '', '', NULL, '2025-05-15 08:20:41.395462+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "1d4e4d74-493a-4758-a5e1-3229a81bae5d", "email": "inna.medeea.lupu@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-15 08:07:38.496818+00', '2025-05-20 05:38:36.999203+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'd707eee8-8de6-49fa-a4a6-00d79d6eded8', 'authenticated', 'authenticated', 'camelya98@yahoo.com', '$2a$10$Lx9nSVhVVN8CbuhRKgjsguyPBNlQqtGQuX/btlQJJBlI.zTg0rsee', '2025-05-16 14:06:31.830489+00', NULL, '', '2025-05-16 14:05:20.123881+00', '', NULL, '', '', NULL, '2025-05-19 09:32:20.435776+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "d707eee8-8de6-49fa-a4a6-00d79d6eded8", "email": "camelya98@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-16 14:05:20.1003+00', '2025-05-22 11:41:23.044365+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'cae70df8-8ff3-4f34-9d75-dae1732f24a7', 'authenticated', 'authenticated', 'lao.water7@gmail.com', '$2a$10$cmXyauQdQyWOtvOgxl1yyO113Xf7VzXn5lShSdlh18ncM0kuLaiZi', '2025-05-21 00:15:39.615135+00', NULL, '', '2025-05-21 00:15:22.366614+00', '', NULL, '', '', NULL, '2025-05-21 02:52:13.826533+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "cae70df8-8ff3-4f34-9d75-dae1732f24a7", "email": "lao.water7@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-21 00:15:22.348216+00', '2025-05-21 02:52:13.866248+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'd0c25236-c4c4-4621-90a1-51f5f4d22d2b', 'authenticated', 'authenticated', 'carmen.talan@yahoo.com', '$2a$10$aIJ2xX8npC7mlfe.2aX1neOT8djvViRmZ6EwFl096OFWY5DCtN1Xy', '2025-05-15 17:56:19.994836+00', NULL, '', '2025-05-15 17:55:54.478521+00', '', NULL, '', '', NULL, '2025-05-16 09:56:30.820552+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "d0c25236-c4c4-4621-90a1-51f5f4d22d2b", "email": "carmen.talan@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-15 17:55:54.456045+00', '2025-05-16 09:56:30.826137+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'cff988c4-74c7-4d89-8ea5-ca57af9c7a7a', 'authenticated', 'authenticated', 'renataiancupsiholog@gmail.com', '$2a$10$UnARZ2NWBUb3uvtrwC2El.lZvwoyLlmz95qHyi5MF4FIqW4mVE5jq', '2025-05-20 15:40:54.510814+00', NULL, '', '2025-05-20 15:40:45.437554+00', '', NULL, '', '', NULL, '2025-05-20 15:40:54.514186+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "cff988c4-74c7-4d89-8ea5-ca57af9c7a7a", "email": "renataiancupsiholog@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-20 15:40:45.431832+00', '2025-05-20 16:43:21.901123+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '1f149689-c4dc-412f-8de6-9b25ee804842', 'authenticated', 'authenticated', 'nutzy_neiconi@yahoo.com', '$2a$10$w5FdRmnkbiHF68yJercTcOQZDpb.wbK5faHv/2Pq3OYTgvmo.tjsC', '2025-05-22 12:44:52.509751+00', NULL, '', '2025-05-22 12:43:42.460519+00', '', NULL, '', '', NULL, '2025-05-22 13:07:33.929572+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "1f149689-c4dc-412f-8de6-9b25ee804842", "email": "nutzy_neiconi@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-22 12:43:42.425316+00', '2025-05-22 13:07:33.935163+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '3bbd94c4-f929-4d5a-9621-721d396f75e3', 'authenticated', 'authenticated', 'psih.alinafr@gmail.com', '$2a$10$OOsd29a1nQ2EasUVdWKjROeWpSZezicPCT3i.5PyBpdKR/rii4wLm', '2025-05-16 09:28:24.84201+00', NULL, '', '2025-05-16 09:27:39.80457+00', '', NULL, '', '', NULL, '2025-05-16 09:28:24.845266+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "3bbd94c4-f929-4d5a-9621-721d396f75e3", "email": "psih.alinafr@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-16 09:27:39.790896+00', '2025-05-16 09:28:24.851616+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '9945cd00-d2ba-494d-9852-4d9ceb75258e', 'authenticated', 'authenticated', 'lilea.emanuelacristina@yahoo.com', '$2a$10$iG2IA/Rq/OiMXmkFv8pqbeXLqc0Ln6upSHXUN33SwJo5jLxChRb6W', '2025-05-19 05:57:49.927143+00', NULL, '', '2025-05-19 05:57:40.62386+00', '', NULL, '', '', NULL, '2025-05-19 05:57:49.931128+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "9945cd00-d2ba-494d-9852-4d9ceb75258e", "email": "lilea.emanuelacristina@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-19 05:57:40.600382+00', '2025-05-19 05:57:49.937742+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '52514d39-b9bc-42e3-8a24-69cd971a8414', 'authenticated', 'authenticated', 'carmenrauta68@yahoo.com', '$2a$10$1az3.fmiA3GMtPRr5s4lkO1U5eZZFIvTbGe365/szZMRsz.lK/TPS', NULL, NULL, '255d91b9b9bcd5550866703a6accfee3509fe2218166153465af3b14', '2025-05-23 04:43:17.503065+00', '', NULL, '', '', NULL, NULL, '{"provider": "email", "providers": ["email"]}', '{"sub": "52514d39-b9bc-42e3-8a24-69cd971a8414", "email": "carmenrauta68@yahoo.com", "email_verified": false, "phone_verified": false}', NULL, '2025-05-16 11:02:28.953052+00', '2025-05-23 04:43:19.464691+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', 'authenticated', 'authenticated', 'sory.loby@gmail.com', '$2a$10$54amig4PMQ7HCubYxsSVje6m3FCnsZyIfeRMPOOQ/bs3uWKLYwTpO', '2025-04-26 14:37:04.959547+00', NULL, '', '2025-04-26 14:27:31.186896+00', '', '2025-04-27 05:14:15.382594+00', '', '', NULL, '2025-05-23 11:22:13.04081+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "e2479383-7ba2-4290-beb7-6e8d08b52ee6", "role": "terapeut", "email": "sory.loby@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-04-26 14:27:31.133784+00', '2025-05-23 12:45:40.112418+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'ab84c874-6fed-45be-9e1d-28da0a041149', 'authenticated', 'authenticated', 'elenadaniele_popa@yahoo.com', '$2a$10$FD39ra3xf0RrXhLTfyBp8eiCOQg2xqZ4AGc.GeMZBeU4i6tymTCI.', '2025-05-19 07:53:58.126672+00', NULL, '', '2025-05-19 07:53:38.697023+00', '', NULL, '', '', NULL, '2025-05-19 07:53:58.134287+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "ab84c874-6fed-45be-9e1d-28da0a041149", "email": "elenadaniele_popa@yahoo.com", "email_verified": true, "phone_verified": false, "invited_by_referral_code": "QTB7MTU6"}', NULL, '2025-05-19 07:53:38.670331+00', '2025-05-19 11:39:44.362554+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'e1ca682f-8dd7-4399-b622-4408513c1c11', 'authenticated', 'authenticated', 'psiho.adrianastiube@gmail.com', NULL, '2025-05-13 09:32:59.597891+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-13 09:32:59.599864+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "101645265700727560830", "name": "Adriana Știube", "email": "psiho.adrianastiube@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocKghYhgHvcyjW7iUHcp3QN1t9-ff0Hcs15i1NA93Va13qbpKIk=s96-c", "full_name": "Adriana Știube", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocKghYhgHvcyjW7iUHcp3QN1t9-ff0Hcs15i1NA93Va13qbpKIk=s96-c", "provider_id": "101645265700727560830", "email_verified": true, "phone_verified": false}', NULL, '2025-05-13 09:32:59.582638+00', '2025-05-13 09:32:59.603108+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'cf18dae6-9d04-4fa7-b284-f4ef1164a1ef', 'authenticated', 'authenticated', 'gorjy.ghy@gmail.com', '$2a$10$ywk8Kj88Fz7KCZRPUrBfUeJYTG1G0fuc.3.ACktLFDSFKgrtJ6wfi', '2025-05-07 07:29:56.380248+00', NULL, '', '2025-05-07 07:29:44.828227+00', '', NULL, '', '', NULL, '2025-05-18 16:53:16.931016+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "cf18dae6-9d04-4fa7-b284-f4ef1164a1ef", "role": "client", "email": "gorjy.ghy@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-07 07:29:44.808564+00', '2025-05-19 01:48:21.673097+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'a830c1a7-13ce-4c8f-96fa-4c7c7bb4085e', 'authenticated', 'authenticated', 'alexandru_georgian09@yahoo.com', '$2a$10$p/M5gNf/rJ3AeIBlSndkpuj2.2pQi3yL6SIV68wXFCyV/uW2Te2/K', '2025-05-13 11:29:32.747242+00', NULL, '', '2025-05-13 11:28:43.193266+00', '', NULL, '', '', NULL, '2025-05-13 11:29:32.751124+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "a830c1a7-13ce-4c8f-96fa-4c7c7bb4085e", "role": "terapeut", "email": "alexandru_georgian09@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-13 11:28:43.174329+00', '2025-05-13 11:29:32.755131+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'df1d2f97-8f64-4160-a909-9039e6619ae3', 'authenticated', 'authenticated', 'psihologandreeadianaion@gmail.com', '$2a$10$24ztqv6KDVkVAXdDDbbeDuBNZCEQOn.pGiOOOzahD.Gys6yubox.W', '2025-05-13 07:50:54.269305+00', NULL, '', '2025-05-13 07:49:31.689715+00', '', NULL, '', '', NULL, '2025-05-13 08:15:14.667851+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "df1d2f97-8f64-4160-a909-9039e6619ae3", "role": "terapeut", "email": "psihologandreeadianaion@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-13 07:49:31.626915+00', '2025-05-13 08:15:14.674753+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'a1e1dcfe-893e-4c00-a4eb-29021630205d', 'authenticated', 'authenticated', 'ralucamihaela.alexandru1984@gmail.com', NULL, '2025-05-19 17:19:58.583607+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-19 17:19:58.585458+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "117594394786742143446", "name": "Raluca Mihaela Alexandru", "email": "ralucamihaela.alexandru1984@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocISa6dLtc83CR2Xkp4TdMo8-2fWTDrfYiupr46sYiTIhHbcgQ=s96-c", "full_name": "Raluca Mihaela Alexandru", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocISa6dLtc83CR2Xkp4TdMo8-2fWTDrfYiupr46sYiTIhHbcgQ=s96-c", "provider_id": "117594394786742143446", "email_verified": true, "phone_verified": false}', NULL, '2025-05-19 17:19:58.559885+00', '2025-05-19 17:19:58.587905+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', 'authenticated', 'authenticated', 'dan.magirescu@innercoach.ro', '$2a$10$GfpQNOnsG2LZzdXy.hPaNONg5b990Du5ayItrvB3asGi2OjE/cYxq', '2025-05-22 14:56:08.86363+00', NULL, '', '2025-05-22 14:55:46.404798+00', '', NULL, '', '', NULL, '2025-05-23 11:39:41.113295+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "de7ba501-a94e-4f86-81b3-0afe662ae8de", "email": "dan.magirescu@innercoach.ro", "email_verified": true, "phone_verified": false}', NULL, '2025-05-22 14:55:46.384216+00', '2025-05-23 11:39:41.124684+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '783f639b-1cab-407c-b1a9-fa510c00396d', 'authenticated', 'authenticated', 'biancanan1979@gmail.com', '$2a$10$YsW735vtRHKKFUUj8ziAGOSmAVy7gUvNRq0IIrTByWfPa0pDys.hS', '2025-05-19 14:12:45.656542+00', NULL, '', '2025-05-19 14:12:06.785157+00', '', NULL, '', '', NULL, '2025-05-19 14:12:45.660559+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "783f639b-1cab-407c-b1a9-fa510c00396d", "email": "biancanan1979@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-19 14:12:06.773242+00', '2025-05-19 14:12:45.670169+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'ae0309b5-4017-4d32-9b5b-74d2f0323837', 'authenticated', 'authenticated', 'sory.loby2@gmail.com', '$2a$10$lFreXviP6KWk1ruBQ1idZ.Pkx0O5DhBnSOVYtbW81kbiYmLk3Ttn6', NULL, NULL, 'aede8c81ef5475f04b3e918d3b4a9fe8b99f0854532eb73320aab90c', '2025-05-07 00:41:00.238346+00', '', NULL, '', '', NULL, NULL, '{"provider": "email", "providers": ["email"]}', '{"sub": "ae0309b5-4017-4d32-9b5b-74d2f0323837", "role": "terapeut", "email": "sory.loby2@gmail.com", "email_verified": false, "phone_verified": false}', NULL, '2025-05-07 00:41:00.19846+00', '2025-05-07 00:41:00.634938+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '76f53ea1-d6bf-4bf7-b88a-918e4062766e', 'authenticated', 'authenticated', 'secrets.of.life.f2p@gmail.com', '$2a$10$2o9wdheSBzRowOmfDaX6t.4EaREjCV8Juf7NPHPCdj/M7M27/0KXK', '2025-05-14 15:37:03.976502+00', NULL, '', '2025-05-14 15:26:28.238115+00', '', NULL, '', '', NULL, '2025-05-20 07:40:34.104762+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "76f53ea1-d6bf-4bf7-b88a-918e4062766e", "email": "secrets.of.life.f2p@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-14 15:26:28.22162+00', '2025-05-20 07:40:34.117535+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '905b3a2e-780e-48f5-b37e-b335d9e97d4a', 'authenticated', 'authenticated', 'loryidu@yahoo.com', '$2a$10$OT626J2Xjgi79KknU3Gdu.4amkG.Hmwg4RgZYZR2GqoaiyxjQLSV2', '2025-05-20 07:47:56.398549+00', NULL, '', '2025-05-20 07:47:13.62964+00', '', NULL, '', '', NULL, '2025-05-20 07:47:56.405+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "905b3a2e-780e-48f5-b37e-b335d9e97d4a", "email": "loryidu@yahoo.com", "email_verified": true, "phone_verified": false, "invited_by_referral_code": "7AY4HJWK"}', NULL, '2025-05-19 15:48:15.430042+00', '2025-05-20 07:47:56.407585+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '3b53ad8e-8faf-48c0-9628-f49ab70ded79', 'authenticated', 'authenticated', 'cosmo.coach.aag@gmail.com', '$2a$10$BFxg20R7wd58uZ.uFKTdque8Uzx9YX6slNr.S5xPKChvu7OvVFzB6', '2025-05-21 10:39:59.957757+00', NULL, '', '2025-05-21 10:38:35.568029+00', '', NULL, '', '', NULL, '2025-05-21 10:39:59.967685+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "3b53ad8e-8faf-48c0-9628-f49ab70ded79", "email": "cosmo.coach.aag@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-21 10:38:35.525024+00', '2025-05-21 19:10:42.918527+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'f10db344-d6f0-4ae3-8ea0-4b1cb2a80894', 'authenticated', 'authenticated', 'psiholog.denisapopescu@gmail.com', '$2a$10$TNW9Kj4Jnyv0jE7M793D/erubLlThLMHFw7ykBEx5gvxIiBj.eYua', '2025-05-14 15:29:28.346346+00', NULL, '', '2025-05-14 15:26:57.188226+00', '', NULL, '', '', NULL, '2025-05-14 15:29:53.104827+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "f10db344-d6f0-4ae3-8ea0-4b1cb2a80894", "role": "terapeut", "email": "psiholog.denisapopescu@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-14 15:26:57.177405+00', '2025-05-14 17:39:50.881269+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '6a5e67bb-c9b1-4b30-b860-3e4db36fcf2f', 'authenticated', 'authenticated', 'psiholog.malinalazar@gmail.com', NULL, '2025-05-15 16:04:01.090432+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-15 16:04:01.093301+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "109380310264740269446", "name": "Mălina Adriana Lazăr", "email": "psiholog.malinalazar@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocJbTBmF5TyrOCEKJ9QzeFKx7WMshDmyIAk-eRYSHLXT_UuV3A=s96-c", "full_name": "Mălina Adriana Lazăr", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocJbTBmF5TyrOCEKJ9QzeFKx7WMshDmyIAk-eRYSHLXT_UuV3A=s96-c", "provider_id": "109380310264740269446", "email_verified": true, "phone_verified": false}', NULL, '2025-05-15 16:04:01.072258+00', '2025-05-15 18:01:05.983882+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '8e441edf-2d91-4551-a4e6-924316cd2090', 'authenticated', 'authenticated', 'contactandreigeorge@yahoo.com', '$2a$10$erHRh/i66I0xYmZw2hd4vekLMrayFim7J5KLn0r3.MN2ZyXWhY3SO', '2025-05-15 06:36:21.740982+00', NULL, '', '2025-05-15 06:35:50.191393+00', '', NULL, '', '', NULL, '2025-05-15 06:36:21.745227+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "8e441edf-2d91-4551-a4e6-924316cd2090", "email": "contactandreigeorge@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-15 06:35:50.186163+00', '2025-05-20 07:48:59.606208+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', 'authenticated', 'authenticated', 'romanica.denisa@gmail.com', NULL, '2025-05-13 08:06:36.8644+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-13 08:06:36.867925+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "100838435522069587668", "name": "Denisa Romanică", "email": "romanica.denisa@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocLXEZRllPZxwAlV6wIKZ42bnbx7zVnM4xlKrTGL0dcOVMsZLw=s96-c", "full_name": "Denisa Romanică", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocLXEZRllPZxwAlV6wIKZ42bnbx7zVnM4xlKrTGL0dcOVMsZLw=s96-c", "provider_id": "100838435522069587668", "email_verified": true, "phone_verified": false}', NULL, '2025-05-13 08:06:36.848029+00', '2025-05-17 10:38:56.585032+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '3497971b-b2c2-4a3a-9a42-420d8a26faec', 'authenticated', 'authenticated', 'kis.monica@yahoo.it', '$2a$10$2uvirlnrip1xXNBItxR/fei/Ts4iahmChSU29IJ/PB4.74D/aK0DC', '2025-05-13 08:19:08.551766+00', NULL, '', '2025-05-13 08:18:59.06067+00', '', NULL, '', '', NULL, '2025-05-13 08:19:08.556434+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "3497971b-b2c2-4a3a-9a42-420d8a26faec", "role": "terapeut", "email": "kis.monica@yahoo.it", "email_verified": true, "phone_verified": false}', NULL, '2025-05-13 08:18:59.045066+00', '2025-05-13 08:19:08.562912+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '89b950c9-a55e-4747-abf4-e403523289d4', 'authenticated', 'authenticated', 'iulia0475@gmail.com', '$2a$10$9IwmW1AXsAxp8DXhHoWItuylnoYKT64DxXUm0cblBZs9zJzcONdyS', NULL, NULL, 'e2f4fd6dc53786d64358b8e5d6f87f052008d7bae20042ef77f050a1', '2025-05-13 10:08:33.853609+00', '', NULL, '', '', NULL, NULL, '{"provider": "email", "providers": ["email"]}', '{"sub": "89b950c9-a55e-4747-abf4-e403523289d4", "role": "terapeut", "email": "iulia0475@gmail.com", "email_verified": false, "phone_verified": false}', NULL, '2025-05-13 10:07:13.469201+00', '2025-05-13 10:08:35.517429+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'aa3c7129-7b21-49e5-b099-19fa2ef0c95f', 'authenticated', 'authenticated', 'amaliacosma@gmail.com', '$2a$10$123ud5PilCpm/f/igKyGNuU4pFeA/RfJIWtlopztRvnoXi6Toytf6', '2025-05-13 08:23:24.349181+00', NULL, '', '2025-05-13 08:22:58.94793+00', '', NULL, '', '', NULL, '2025-05-13 08:25:05.011028+00', '{"provider": "email", "providers": ["email", "google"]}', '{"iss": "https://accounts.google.com", "sub": "106484611114442117643", "name": "Amalia Tamas", "role": "terapeut", "email": "amaliacosma@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocIJnWj2URzkZgrS5-Ag26bF3iYhiWsC2q1zmtd8ffhUmcBwSlGeOw=s96-c", "full_name": "Amalia Tamas", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocIJnWj2URzkZgrS5-Ag26bF3iYhiWsC2q1zmtd8ffhUmcBwSlGeOw=s96-c", "provider_id": "106484611114442117643", "email_verified": true, "phone_verified": false}', NULL, '2025-05-13 08:19:48.394889+00', '2025-05-13 08:25:05.014016+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '49af0fde-1e09-4899-85d0-42f87dc62ad7', 'authenticated', 'authenticated', 'mihocbogdan96@gmail.com', '$2a$10$ckcmZ83KAAdBlWJ/AOqmAuJIGBhMrtelTF1BZTYPhhuQJdcUPJEIe', '2025-05-16 08:24:36.214485+00', NULL, '', '2025-05-16 08:24:19.316485+00', '', NULL, '', '', NULL, '2025-05-16 19:43:13.594296+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "49af0fde-1e09-4899-85d0-42f87dc62ad7", "email": "mihocbogdan96@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-16 08:24:19.280419+00', '2025-05-18 09:33:13.643833+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'c7fc72ce-3614-4d3a-a617-c7b5aa2d9cd0', 'authenticated', 'authenticated', 'ageorgescu22@yahoo.com', '$2a$10$O5.Ep0iPo9g4ugZj/WrN7u./Aw0GUfEaPvfIV9G8bm2y6liwjV3ai', NULL, NULL, '3993401fd20c9e9cdb53df81f410eb63d94e5513b0ef962e33fc49ed', '2025-05-16 09:42:57.962302+00', '', NULL, '', '', NULL, NULL, '{"provider": "email", "providers": ["email"]}', '{"sub": "c7fc72ce-3614-4d3a-a617-c7b5aa2d9cd0", "email": "ageorgescu22@yahoo.com", "email_verified": false, "phone_verified": false}', NULL, '2025-05-16 09:42:57.948048+00', '2025-05-16 09:42:58.370989+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '433c694d-a26a-44cb-84cc-45f84d7daf07', 'authenticated', 'authenticated', 'camyblaga@yahoo.com', '$2a$10$thTr/BqCWhkoj8eOZqrTCuuPqsfEe8vpCyS5qaq7k1F5maG3AGwHe', '2025-05-15 06:35:52.214729+00', NULL, '', '2025-05-15 06:35:23.71133+00', '', NULL, '', '', NULL, '2025-05-15 07:12:49.632636+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "433c694d-a26a-44cb-84cc-45f84d7daf07", "email": "camyblaga@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-15 06:35:23.670308+00', '2025-05-15 07:12:49.637401+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'c727ce88-386f-49e6-88c9-df7115e793e5', 'authenticated', 'authenticated', 'gianinacornea@yahoo.com', '$2a$10$Zx9Jkr3Lz72gA0xQCVy3Der.2wygawNISV9Frh7YVISadJUDwyQDW', '2025-05-19 08:08:05.820111+00', NULL, '', '2025-05-19 08:07:16.768647+00', '', NULL, '', '', NULL, '2025-05-19 08:08:05.824334+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "c727ce88-386f-49e6-88c9-df7115e793e5", "email": "gianinacornea@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-19 08:07:16.756349+00', '2025-05-19 08:08:05.833843+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '07a95865-754b-4fed-ae0a-d4b69c486190', 'authenticated', 'authenticated', 'carmendadu@gmail.com', '$2a$10$.ObV6zva0s68vGrVo8sxcO6c/yRYwn64KX2G4sqczaS59IaQBdIUy', '2025-05-15 12:21:29.348171+00', NULL, '', '2025-05-15 12:21:19.355598+00', '', NULL, '', '', NULL, '2025-05-15 13:06:21.691933+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "07a95865-754b-4fed-ae0a-d4b69c486190", "email": "carmendadu@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-15 12:21:19.337202+00', '2025-05-15 13:06:21.698413+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8', 'authenticated', 'authenticated', 'adryma2016@yahoo.com', '$2a$10$Wx7WTty3grQpmaJ5V6MEYuAdkD1ZQsV2xDivWMnmOAnl1G0jz08Qu', '2025-05-19 14:53:16.848919+00', NULL, '', '2025-05-19 14:52:44.308118+00', '', NULL, '', '', NULL, '2025-05-19 14:53:16.86036+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8", "email": "adryma2016@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-19 14:52:44.287212+00', '2025-05-22 13:20:04.887019+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '12389e53-ab41-4ff5-90ee-c3593e2b84cc', 'authenticated', 'authenticated', 'andriescu.diana98@gmail.com', NULL, '2025-05-13 15:56:43.192756+00', NULL, '', '2025-05-13 15:52:44.880918+00', '', NULL, '', '', NULL, '2025-05-14 13:45:20.169181+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "100284568331088922268", "name": "ANDRIESCU DIANA", "email": "andriescu.diana98@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocI_FCZZaXB04Rhye3-DmVq3RFB8GCOnBWmIJBaEuSHgoHwes9dYJg=s96-c", "full_name": "ANDRIESCU DIANA", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocI_FCZZaXB04Rhye3-DmVq3RFB8GCOnBWmIJBaEuSHgoHwes9dYJg=s96-c", "provider_id": "100284568331088922268", "email_verified": true, "phone_verified": false}', NULL, '2025-05-13 14:50:53.653381+00', '2025-05-14 13:45:20.182246+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '7733575e-14a6-48a4-bf21-b7901b8d6714', 'authenticated', 'authenticated', 'suciaghialexandrushorts@gmail.com', NULL, '2025-05-15 06:23:30.379925+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-15 06:23:30.383166+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "117161663538106023093", "name": "Alex Suciaghi", "email": "suciaghialexandrushorts@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocKgwFNjoaehEzyQMHWZWj55QyAKPD-uzgq0XbdGdGjzU4fkwg=s96-c", "full_name": "Alex Suciaghi", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocKgwFNjoaehEzyQMHWZWj55QyAKPD-uzgq0XbdGdGjzU4fkwg=s96-c", "provider_id": "117161663538106023093", "email_verified": true, "phone_verified": false}', NULL, '2025-05-15 06:23:30.349085+00', '2025-05-19 11:28:22.447563+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '8d983543-4636-4bce-a1b8-d0d5e9c2f88f', 'authenticated', 'authenticated', 'office@mobilamoll.ro', '$2a$10$qQjNHe.Qssy6YWBfJcrniu1yp4mmv9iqngXzKV1mVht7tdkRDQ7gm', '2025-05-19 16:36:04.013323+00', NULL, '', '2025-05-19 16:31:07.79663+00', '', NULL, '', '', NULL, '2025-05-19 16:36:04.021532+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "8d983543-4636-4bce-a1b8-d0d5e9c2f88f", "email": "office@mobilamoll.ro", "email_verified": true, "phone_verified": false}', NULL, '2025-05-19 16:31:07.78265+00', '2025-05-19 17:34:53.764966+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'c07e8742-9b26-4257-80d8-81ea920e3722', 'authenticated', 'authenticated', 'cbuzea30@gmail.com', NULL, '2025-05-13 18:37:38.502236+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-13 20:01:00.466047+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "101090285835352151677", "name": "Cristina Buzea", "email": "cbuzea30@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocJBXiByUZ_l6CHaMswX2Mad1mGAzV1LKIC4hKjboET6xCJn80yx=s96-c", "full_name": "Cristina Buzea", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocJBXiByUZ_l6CHaMswX2Mad1mGAzV1LKIC4hKjboET6xCJn80yx=s96-c", "provider_id": "101090285835352151677", "email_verified": true, "phone_verified": false}', NULL, '2025-05-13 18:37:38.480093+00', '2025-05-20 07:43:51.175855+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '622d14e0-2b33-4c8b-81d5-231a707fd100', 'authenticated', 'authenticated', 'pogaci2@gmail.com', NULL, '2025-05-20 07:02:39.053891+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-20 07:02:39.05791+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "104495585733168663899", "name": "Gabriela Pogaci", "email": "pogaci2@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocIAr1GaNSj_Sy_e_yCfsJ0ZZEdLlUCF15KFK6IqiqJzmU3WApE=s96-c", "full_name": "Gabriela Pogaci", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocIAr1GaNSj_Sy_e_yCfsJ0ZZEdLlUCF15KFK6IqiqJzmU3WApE=s96-c", "provider_id": "104495585733168663899", "email_verified": true, "phone_verified": false}', NULL, '2025-05-20 07:02:39.031217+00', '2025-05-20 08:00:56.660117+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '072aa24d-bfc3-4b0c-93f2-1435906d8381', 'authenticated', 'authenticated', 'dianasimutm@gmail.com', NULL, '2025-05-20 07:34:37.662302+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-20 07:34:37.664876+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "117698560013326264927", "name": "Diana Olivia Simu", "email": "dianasimutm@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocI4g-wzezTB5WIYT1HjaC1NL5i1tKYoPXR1ySXyjUYWlD8BZZoW8Q=s96-c", "full_name": "Diana Olivia Simu", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocI4g-wzezTB5WIYT1HjaC1NL5i1tKYoPXR1ySXyjUYWlD8BZZoW8Q=s96-c", "provider_id": "117698560013326264927", "email_verified": true, "phone_verified": false}', NULL, '2025-05-20 07:34:37.635316+00', '2025-05-21 11:54:11.123047+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '6a70d9b5-4fb8-46f7-975b-5887fd4e47de', 'authenticated', 'authenticated', 'meri.velciu@gmail.com', NULL, '2025-05-21 07:26:09.538667+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-21 07:26:09.545086+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "116655270411373041793", "name": "Meri Velciu", "email": "meri.velciu@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocIlMFkvPfnVjp5iphYJFTrtWZKfrteF_o1DvvksyQGuUZpIjaL_=s96-c", "full_name": "Meri Velciu", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocIlMFkvPfnVjp5iphYJFTrtWZKfrteF_o1DvvksyQGuUZpIjaL_=s96-c", "provider_id": "116655270411373041793", "email_verified": true, "phone_verified": false}', NULL, '2025-05-21 07:26:09.478807+00', '2025-05-21 13:04:14.713685+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '1375c34c-1b05-438e-8f4f-eeb5f0d373f8', 'authenticated', 'authenticated', 'valentinpascariu85@gmail.com', NULL, '2025-05-15 09:53:23.152783+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-15 09:53:23.155265+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "118205813660254822363", "name": "Valentin Pascariu", "email": "valentinpascariu85@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocKSFTLsU2ZvPBcf6KBdX7f6S9ItM5cIQIQKohsYzb5QBqOl_ATe=s96-c", "full_name": "Valentin Pascariu", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocKSFTLsU2ZvPBcf6KBdX7f6S9ItM5cIQIQKohsYzb5QBqOl_ATe=s96-c", "provider_id": "118205813660254822363", "email_verified": true, "phone_verified": false}', NULL, '2025-05-15 09:53:23.135806+00', '2025-05-15 14:27:57.537218+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'a7e4662b-0ae7-4687-98f5-a35387a707be', 'authenticated', 'authenticated', 'iozsiangelica@gmail.com', NULL, '2025-05-15 16:42:14.564693+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-15 16:42:14.566581+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "113047692070349041732", "name": "Angelica Iozsi", "email": "iozsiangelica@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocLlX8FxtNX2KB7LCJ-BOXpJO5PzVlsXp6t8uiLxTtBtKJrJNzaL=s96-c", "full_name": "Angelica Iozsi", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocLlX8FxtNX2KB7LCJ-BOXpJO5PzVlsXp6t8uiLxTtBtKJrJNzaL=s96-c", "provider_id": "113047692070349041732", "email_verified": true, "phone_verified": false}', NULL, '2025-05-15 16:42:14.541152+00', '2025-05-15 16:42:14.570295+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'feea398b-e2c0-4217-be62-0da00ee5ac3b', 'authenticated', 'authenticated', 'complet.definit@yahoo.com', '$2a$10$9CjBoQRLacaDRTAXndiJY.6W9sHeUZqqGRsOt78KYDvH7h7v9wytO', '2025-05-19 11:59:14.678612+00', NULL, '', '2025-05-19 11:58:16.41776+00', '', NULL, '', '', NULL, '2025-05-19 11:59:14.682341+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "feea398b-e2c0-4217-be62-0da00ee5ac3b", "email": "complet.definit@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-19 11:58:16.390824+00', '2025-05-19 15:10:07.842706+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '512c3b3b-0fa0-4659-8c0e-daccd911baa6', 'authenticated', 'authenticated', 'petruspop.catalina@gmail.com', NULL, '2025-05-16 09:10:55.517355+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-16 09:10:55.519637+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "103869521089619563567", "name": "Cătălina Petruș-Pop", "email": "petruspop.catalina@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocIflS6SF0oWEmKgQh966E7yAIWpysoq0xgmp6oziAb1PNgnm6YB=s96-c", "full_name": "Cătălina Petruș-Pop", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocIflS6SF0oWEmKgQh966E7yAIWpysoq0xgmp6oziAb1PNgnm6YB=s96-c", "provider_id": "103869521089619563567", "email_verified": true, "phone_verified": false}', NULL, '2025-05-16 09:10:55.503172+00', '2025-05-16 09:10:55.522435+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '398915d4-fa9b-430f-acd0-c44c6197221b', 'authenticated', 'authenticated', 'adrianamindful@gmail.com', NULL, '2025-05-22 12:56:47.026247+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-22 12:56:47.028095+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "106061337861431131595", "name": "Adriana - Mindful Psychology", "email": "adrianamindful@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocIFrBxsn8JyOUocdRvMthpT6Kv5UUGQx3oekhz_kuS__neULeWq=s96-c", "full_name": "Adriana - Mindful Psychology", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocIFrBxsn8JyOUocdRvMthpT6Kv5UUGQx3oekhz_kuS__neULeWq=s96-c", "provider_id": "106061337861431131595", "email_verified": true, "phone_verified": false}', NULL, '2025-05-22 12:56:47.010314+00', '2025-05-22 22:08:59.604848+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'd1792c86-294f-453e-ae1e-8474ab5553e3', 'authenticated', 'authenticated', 'mihaelastanciu999@gmail.com', '$2a$10$zhlFEt9IObEhumM5ZCxrVuet8oZqTyCPdToSk8ZD/c76c27i6G7iy', '2025-05-16 10:43:17.044981+00', NULL, '', '2025-05-16 10:42:59.922878+00', '', NULL, '', '', NULL, '2025-05-16 10:43:17.049203+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "d1792c86-294f-453e-ae1e-8474ab5553e3", "email": "mihaelastanciu999@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-16 10:42:59.914702+00', '2025-05-16 10:43:17.051069+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '23584fae-eae0-4163-9e12-0e8fc3d4047e', 'authenticated', 'authenticated', 'geaninabasturescu@gmail.com', '$2a$10$AF0uyRKwsiU86j2gq7.tvOPBu400Bgi4eAC9sGuIv0J9.pVb4662a', '2025-05-19 06:01:06.647578+00', NULL, '', '2025-05-19 06:00:38.295753+00', '', NULL, '', '', NULL, '2025-05-19 06:01:06.651853+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "23584fae-eae0-4163-9e12-0e8fc3d4047e", "email": "geaninabasturescu@gmail.com", "email_verified": true, "phone_verified": false, "invited_by_referral_code": "QTB7MTU6"}', NULL, '2025-05-19 06:00:38.285829+00', '2025-05-19 06:01:06.654479+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '7617e0bf-ca39-47d8-a708-935afb8eaf87', 'authenticated', 'authenticated', 'laura_stan80@yahoo.com', '$2a$10$zEnvUQ9Crmrvm1rW9ibRoe07XjrSfRlDZLrqbWUSOfo/DMfhFsiuq', '2025-05-17 05:30:31.771175+00', NULL, '', '2025-05-17 05:29:41.073248+00', '', NULL, '', '', NULL, '2025-05-19 05:01:04.943548+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "7617e0bf-ca39-47d8-a708-935afb8eaf87", "email": "laura_stan80@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-17 05:29:41.032367+00', '2025-05-19 06:45:01.305782+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '459220a9-338b-4a45-8533-24789a3b1da7', 'authenticated', 'authenticated', 'miusimplu@gmail.com', NULL, '2025-05-18 13:24:52.972434+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-18 13:24:52.978394+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "111777482259273280547", "name": "Miu Simplu", "email": "miusimplu@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocLttJHu6elvoOiw2cmkUjS5oPVJbu7_eZeHqrJaLpaKgcoK-g=s96-c", "full_name": "Miu Simplu", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocLttJHu6elvoOiw2cmkUjS5oPVJbu7_eZeHqrJaLpaKgcoK-g=s96-c", "provider_id": "111777482259273280547", "email_verified": true, "phone_verified": false}', NULL, '2025-05-18 13:24:52.92457+00', '2025-05-18 13:24:52.988859+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '3e6b8532-e559-4bba-a913-9178fdb2a0bd', 'authenticated', 'authenticated', 'brifsorina@gmail.com', NULL, '2025-05-16 10:42:46.608449+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-16 10:42:46.610446+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "104747477963223972382", "name": "Sorina Brif", "email": "brifsorina@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocI-wCDX0_UUtMuxQ3NgVV9tN6gDGm__w4YcGACMcDIp2GXAeQ=s96-c", "full_name": "Sorina Brif", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocI-wCDX0_UUtMuxQ3NgVV9tN6gDGm__w4YcGACMcDIp2GXAeQ=s96-c", "provider_id": "104747477963223972382", "email_verified": true, "phone_verified": false}', NULL, '2025-05-16 10:42:46.592252+00', '2025-05-21 17:19:42.667248+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '13640682-e72c-448d-87a7-af45f1070498', 'authenticated', 'authenticated', 'vali_robu@yahoo.com', '$2a$10$dCacyNlVjnMZdqTat0K1ZORVmkpKce20/Pq.QmWOar5T.Si.OBd/.', '2025-05-16 12:30:27.456897+00', NULL, '', '2025-05-16 12:24:25.746799+00', '', NULL, '', '', NULL, '2025-05-16 18:28:24.97476+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "13640682-e72c-448d-87a7-af45f1070498", "email": "vali_robu@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-16 12:24:25.720436+00', '2025-05-17 19:08:57.740846+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '3add3342-f74c-49c7-985b-238208eebac5', 'authenticated', 'authenticated', 'terapeutdenisaelena@gmail.com', '$2a$10$mdJutNdPsuXiBICuCoy4z.5kE/BvcB2X74w12NikRNgwZLYJbZH5m', '2025-05-19 08:57:17.585164+00', NULL, '', '2025-05-19 08:56:43.559292+00', '', NULL, '', '', NULL, '2025-05-19 08:57:38.074205+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "3add3342-f74c-49c7-985b-238208eebac5", "email": "terapeutdenisaelena@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-19 08:56:43.547833+00', '2025-05-19 08:57:38.078672+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '4240bff7-8190-4157-bc20-1b64f6e24ca8', 'authenticated', 'authenticated', 'hellosuciaghi@gmail.com', NULL, '2025-05-21 08:18:03.761792+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-21 08:18:03.764563+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "111848928485748322119", "name": "hellosuciaghi", "email": "hellosuciaghi@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocL_6jE-fJppyScXhSpxLSsjFQ2XEE-O13zfZnsjRNBzYmwYCQ=s96-c", "full_name": "hellosuciaghi", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocL_6jE-fJppyScXhSpxLSsjFQ2XEE-O13zfZnsjRNBzYmwYCQ=s96-c", "provider_id": "111848928485748322119", "email_verified": true, "phone_verified": false}', NULL, '2025-05-21 08:18:03.742512+00', '2025-05-21 12:40:12.270447+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '1aa4f7e2-f7f1-4b27-a7bd-f2595a5fdfce', 'authenticated', 'authenticated', 'd_lupu@ymail.com', '$2a$10$TvcjtZecIdyyhPXau8XIeOcrgul7Dz1IQjwQsayF3h/z8NbDCArLm', '2025-05-20 18:43:57.474955+00', NULL, '', '2025-05-20 18:42:57.470334+00', '', NULL, '', '', NULL, '2025-05-20 19:34:52.977318+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "1aa4f7e2-f7f1-4b27-a7bd-f2595a5fdfce", "email": "d_lupu@ymail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-20 18:42:57.441408+00', '2025-05-20 19:34:52.985609+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '99556ce6-0304-4614-aeba-0c2f3d73a9f6', 'authenticated', 'authenticated', 'psiholog.kerteszreka@gmail.com', '$2a$10$Qg0DP.TEKJWC/z3fIsa26ueOmjAmFfLu2EZk1wFrE28S6yL62igpK', '2025-05-21 07:50:09.5493+00', NULL, '', '2025-05-21 07:49:50.81248+00', '', NULL, '', '', NULL, '2025-05-21 07:50:09.553498+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "99556ce6-0304-4614-aeba-0c2f3d73a9f6", "email": "psiholog.kerteszreka@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-21 07:49:50.789487+00', '2025-05-21 13:50:24.550613+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '1bc4edd2-b5de-4b77-abb8-ffdad01efa4c', 'authenticated', 'authenticated', 'valentinfionut@yahoo.com', '$2a$10$NmVvbZyE5x9RJlxCj5oGaeu.NLpIXQfyjvtIszdpF9ZwTjslMwPqK', '2025-05-19 15:12:24.382143+00', NULL, '', '2025-05-19 15:11:30.342966+00', '', NULL, '', '', NULL, '2025-05-19 15:12:24.384883+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "1bc4edd2-b5de-4b77-abb8-ffdad01efa4c", "email": "valentinfionut@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-19 15:11:30.335961+00', '2025-05-19 15:12:24.386762+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'e9af8519-44db-48ee-9e9d-b7fe14ccc7a5', 'authenticated', 'authenticated', 'izabella.cete@gmail.com', '$2a$10$GRx1eo68t1DEJ22NR0ryVObSnjEPXLGUFT64Ep0Kr7z1wkenABBN2', '2025-05-21 11:46:26.07071+00', NULL, '', '2025-05-21 11:46:12.368293+00', '', NULL, '', '', NULL, '2025-05-21 11:46:55.54159+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "e9af8519-44db-48ee-9e9d-b7fe14ccc7a5", "email": "izabella.cete@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-21 11:46:12.343402+00', '2025-05-21 11:46:55.543454+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'dd8d0335-6696-4fb6-b186-31a0533d9587', 'authenticated', 'authenticated', 'adrianakarabuber79@gmail.com', '$2a$10$qKzMau.lm3k4/N7wWpukMe6b9xXZ0vDT20/sStJWlJtNGFoGJue2y', '2025-05-19 15:10:47.206906+00', NULL, '', '2025-05-19 15:10:24.359725+00', '', NULL, '', '', NULL, '2025-05-19 15:10:47.21387+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "dd8d0335-6696-4fb6-b186-31a0533d9587", "email": "adrianakarabuber79@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-19 15:10:24.343132+00', '2025-05-21 12:34:06.732294+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '7f541d24-fa47-444f-9ca4-f4f7bc3f4dde', 'authenticated', 'authenticated', 'ioanalexandruturcu@gmail.com', '$2a$10$tFtVhjWU2fbP7gOgOfiUA.vCxf7lLz4ew86IzgHUSfX/I2Bw049fK', '2025-05-20 06:34:37.309098+00', NULL, '', '2025-05-20 06:09:41.957243+00', '', NULL, '', '', NULL, '2025-05-20 06:34:37.330319+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "7f541d24-fa47-444f-9ca4-f4f7bc3f4dde", "email": "ioanalexandruturcu@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-20 06:09:41.938539+00', '2025-05-20 14:10:19.010011+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'ae26134b-38c8-4748-8770-5b73d79cae08', 'authenticated', 'authenticated', 'teomury@gmail.com', '$2a$10$wreGBVoH/ollpH0d0zrcSOcmuMlDiyYzWqtN20EDjAKzozNtWJTjO', '2025-05-20 11:49:51.64167+00', NULL, '', '2025-05-20 11:49:42.512599+00', '', NULL, '', '', NULL, '2025-05-21 20:19:14.937738+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "ae26134b-38c8-4748-8770-5b73d79cae08", "email": "teomury@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-20 11:49:42.473611+00', '2025-05-23 08:01:22.451695+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '1bd491bf-3874-47d1-a4ed-0983f63a866e', 'authenticated', 'authenticated', 'terapeutholistic.eliseiadam@gmail.com', '$2a$10$oUKW4MmDw0zsxP5yVlIZJuLWw7amzNFpgGawwa7Ui3WNsIAElxkl2', '2025-05-22 13:28:23.48139+00', NULL, '', '2025-05-22 13:26:55.571593+00', '', NULL, '', '', NULL, '2025-05-22 13:37:19.095206+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "1bd491bf-3874-47d1-a4ed-0983f63a866e", "email": "terapeutholistic.eliseiadam@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-22 13:26:55.561047+00', '2025-05-23 11:33:56.348229+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '20d55537-6f54-41d6-98a6-474174099d17', 'authenticated', 'authenticated', 'carmenam_ro@yahoo.com', '$2a$10$NUt5deJ3MllSbhD8qpUEL.nJ7d4ZYPmhaRpIqN33EwKbdrMsmxHuW', '2025-05-20 21:40:22.164178+00', NULL, '', '2025-05-20 21:37:36.171798+00', '', NULL, '', '', NULL, '2025-05-20 21:40:22.171941+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "20d55537-6f54-41d6-98a6-474174099d17", "email": "carmenam_ro@yahoo.com", "email_verified": true, "phone_verified": false, "invited_by_referral_code": "QTB7MTU6"}', NULL, '2025-05-20 21:37:36.1523+00', '2025-05-22 20:43:03.276345+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '5690ddb1-c997-4a3e-895a-06b93dab6ec4', 'authenticated', 'authenticated', 'pintea.daiana1399@gmail.com', '$2a$10$ElaywJFs6L5XFqfB6Fo.o.RC2XgrVYc1wcHxY/Zlaqrj.N.JpDEye', '2025-05-21 07:53:06.568008+00', NULL, '', '2025-05-21 07:52:05.118552+00', '', NULL, '', '', NULL, '2025-05-21 08:02:37.002387+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "5690ddb1-c997-4a3e-895a-06b93dab6ec4", "email": "pintea.daiana1399@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-21 07:52:05.102035+00', '2025-05-21 08:02:37.011991+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '147fcc1b-10f1-4184-9d95-d09505d736fa', 'authenticated', 'authenticated', 'ionutrus231@gmail.com', '$2a$10$bZDpw9OO1AC0zAWsJA7mFulDVRX69juS85fAytFnBNY1l/9iYkJ2.', '2025-05-22 13:46:40.990651+00', NULL, '', '2025-05-22 13:45:54.481305+00', '', NULL, '', '', NULL, '2025-05-23 05:47:00.88101+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "147fcc1b-10f1-4184-9d95-d09505d736fa", "email": "ionutrus231@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-22 13:45:54.45713+00', '2025-05-23 05:47:00.903058+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '4b6f4102-c588-406c-a091-79dd2485fb81', 'authenticated', 'authenticated', 'suciaghi97@gmail.com', NULL, '2025-05-01 16:13:19.548072+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-22 15:20:40.553994+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "100178659624070148668", "name": "Suciaghi Alexandru", "email": "suciaghi97@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocLJeFxw6SnATf0wdZDyBDolGgpI3B_ZhIPiEHsCInszsXjkWQ=s96-c", "full_name": "Suciaghi Alexandru", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocLJeFxw6SnATf0wdZDyBDolGgpI3B_ZhIPiEHsCInszsXjkWQ=s96-c", "provider_id": "100178659624070148668", "email_verified": true, "phone_verified": false}', NULL, '2025-05-01 16:13:19.537825+00', '2025-05-22 15:20:40.556443+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '53c97092-2634-4c47-ad83-808566dfbdcd', 'authenticated', 'authenticated', 'psiholog.cristina-avram@outlook.com', '$2a$10$4ks0lN5iU2KgpLGhd80ZkOH9982ZuZWt1cNGwI6dtWA8mCMdF6dQO', '2025-05-19 09:42:54.739682+00', NULL, '', '2025-05-19 09:42:38.95007+00', '', NULL, '', '', NULL, '2025-05-19 09:42:54.745129+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "53c97092-2634-4c47-ad83-808566dfbdcd", "email": "psiholog.cristina-avram@outlook.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-19 09:42:38.941033+00', '2025-05-19 09:42:54.748681+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'a6f658f8-149d-4063-b1d9-c54105f03392', 'authenticated', 'authenticated', 'nicoldina1974@gmail.com', '$2a$10$WvQxPOGG0klT1yjuDIPhu.ZRe9t.iV6owUAx6jxLgxNaNnUnD56ua', '2025-05-19 09:41:32.126555+00', NULL, '', '2025-05-19 09:41:14.746251+00', '', NULL, '', '', NULL, '2025-05-19 09:41:32.136907+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "a6f658f8-149d-4063-b1d9-c54105f03392", "email": "nicoldina1974@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-19 09:41:14.645853+00', '2025-05-19 10:39:44.104474+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '682d23b2-3bb3-4f55-9f23-5b7689983e82', 'authenticated', 'authenticated', 'alexandra.pandelea88@gmail.com', '$2a$10$uhAmDi1Clq0ur.CMqeeonO0p6YiRVeAsE6c7w94T9fkF1YofLOs4u', '2025-05-20 13:30:25.114717+00', NULL, '', '2025-05-20 13:30:14.590867+00', '', NULL, '', '', NULL, '2025-05-20 13:30:25.119111+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "682d23b2-3bb3-4f55-9f23-5b7689983e82", "email": "alexandra.pandelea88@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-20 13:30:14.564693+00', '2025-05-23 06:41:38.908921+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '3e9a53b2-aefd-4282-b37a-ee95f47dfe77', 'authenticated', 'authenticated', 'violetapal65@gmail.com', '$2a$10$BDqQEXVQPzzlfwcrfXEpP.tb1wy4XTqCIidT12zElAokdgrA4kEsy', '2025-05-19 15:44:27.345708+00', NULL, '', '2025-05-19 15:43:58.959405+00', '', NULL, '', '', NULL, '2025-05-19 15:44:27.349459+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "3e9a53b2-aefd-4282-b37a-ee95f47dfe77", "email": "violetapal65@gmail.com", "email_verified": true, "phone_verified": false, "invited_by_referral_code": "7AY4HJWK"}', NULL, '2025-05-19 15:43:58.941001+00', '2025-05-19 15:44:27.359081+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'd3275dfe-f4df-44fc-acaa-659e92369e66', 'authenticated', 'authenticated', 'danutjilavu@yahoo.com', '$2a$10$95tYF6GqONQyRg7vkCyPyOUfAeAuinMNuNvyqFPDkD9GcNPtdG/Nq', '2025-05-20 06:35:10.146729+00', NULL, '', '2025-05-20 06:34:44.759694+00', '', NULL, '', '', NULL, '2025-05-20 06:35:10.151286+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "d3275dfe-f4df-44fc-acaa-659e92369e66", "email": "danutjilavu@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-20 06:34:44.744883+00', '2025-05-23 07:06:08.123707+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', 'a3c141d5-a60e-4211-99ce-d1828f4174cf', 'authenticated', 'authenticated', 'ggabicoz@gmail.com', '$2a$10$cOo8HjXj1YCt1HQvvEM3M.rWcK1yc65o1z3sAedy4KxX2V0c5I9hG', '2025-05-21 14:02:20.435142+00', NULL, '', '2025-05-21 14:01:50.268496+00', '', NULL, '', '', NULL, '2025-05-21 14:02:20.43954+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "a3c141d5-a60e-4211-99ce-d1828f4174cf", "email": "ggabicoz@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-21 14:01:50.227804+00', '2025-05-21 14:02:20.451453+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '7b00956b-eafb-4d19-aed0-67dad9ab51ee', 'authenticated', 'authenticated', 'lica.mara.c02@gmail.com', NULL, '2025-05-20 12:19:40.700878+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-20 12:19:40.702766+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "101927015616279710709", "name": "Maria Lica", "email": "lica.mara.c02@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocJRGhMX7sPQAicMs-9jWcfU0l96SoKXHegRXXQ0sMWfy5m63Q=s96-c", "full_name": "Maria Lica", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocJRGhMX7sPQAicMs-9jWcfU0l96SoKXHegRXXQ0sMWfy5m63Q=s96-c", "provider_id": "101927015616279710709", "email_verified": true, "phone_verified": false}', NULL, '2025-05-20 12:19:40.680175+00', '2025-05-20 13:23:38.36333+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '3a317800-976d-4277-a491-27d7962bb16b', 'authenticated', 'authenticated', 'suciaghialex@gmail.com', '$2a$10$ng36pin/WmZk7.wf1SsKD.aiaYVR3DEc8UPQKznrxZta82DMaOfHi', '2025-05-20 05:32:51.055481+00', NULL, '', '2025-05-20 05:30:09.466313+00', '', NULL, '', '', NULL, '2025-05-22 15:19:58.05771+00', '{"provider": "google", "providers": ["google", "email"]}', '{"iss": "https://accounts.google.com", "sub": "111736287324672843371", "name": "Alexandru Suciaghi", "email": "suciaghialex@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocJ5N61hhK8Uh223mxMwBr4MsUf7-6ZQaMdFTHJ4do9KMxbJ3G4=s96-c", "full_name": "Alexandru Suciaghi", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocJ5N61hhK8Uh223mxMwBr4MsUf7-6ZQaMdFTHJ4do9KMxbJ3G4=s96-c", "provider_id": "111736287324672843371", "email_verified": true, "phone_verified": false}', NULL, '2025-05-20 05:30:09.442591+00', '2025-05-22 15:19:58.064485+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '98daacc7-a021-4869-b7d3-33599178f966', 'authenticated', 'authenticated', 'laura.mera1128@gmail.com', NULL, '2025-05-22 06:54:03.062697+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-22 06:54:03.070917+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "107883845136753509499", "name": "Laura Mera", "email": "laura.mera1128@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocKfuqWJGKt6nJa1rZnooKD7eieIIjRQuWgxX16u9J5ppd6h0w=s96-c", "full_name": "Laura Mera", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocKfuqWJGKt6nJa1rZnooKD7eieIIjRQuWgxX16u9J5ppd6h0w=s96-c", "provider_id": "107883845136753509499", "email_verified": true, "phone_verified": false}', NULL, '2025-05-22 06:54:02.995569+00', '2025-05-22 06:54:03.082955+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '1e8e19fd-7346-4d83-807e-404c01903baf', 'authenticated', 'authenticated', 'baciu.raul555@gmail.com', '$2a$10$3xrFpx9Z/47W6vW40Qccy..T6IxHMtxEOuHImqkCW/ztCMzKd4Lre', '2025-05-20 23:59:40.843493+00', NULL, '', '2025-05-20 23:50:00.60859+00', '', NULL, '', '', NULL, '2025-05-21 03:45:02.997544+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "1e8e19fd-7346-4d83-807e-404c01903baf", "email": "baciu.raul555@gmail.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-20 23:50:00.569344+00', '2025-05-23 05:09:14.021255+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', 'authenticated', 'authenticated', 'sandu_elena1998@yahoo.com', '$2a$10$aXbDGeEyFFk5A9rAkq.yGO.Ngtq3EcWkKT6/Vod.9liK38.N4zI/.', '2025-05-22 14:37:53.967927+00', NULL, '', '2025-05-22 14:37:27.352604+00', '', NULL, '', '', NULL, '2025-05-22 14:37:53.972342+00', '{"provider": "email", "providers": ["email"]}', '{"sub": "8458bab3-1fb1-4eb7-8cad-f555bc58fc8f", "email": "sandu_elena1998@yahoo.com", "email_verified": true, "phone_verified": false}', NULL, '2025-05-22 14:37:27.328349+00', '2025-05-22 14:37:53.984529+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false),
	('00000000-0000-0000-0000-000000000000', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', 'authenticated', 'authenticated', 'meli.havadi@gmail.com', NULL, '2025-05-21 08:30:30.694124+00', NULL, '', NULL, '', NULL, '', '', NULL, '2025-05-22 13:25:41.109924+00', '{"provider": "google", "providers": ["google"]}', '{"iss": "https://accounts.google.com", "sub": "109207201963727215313", "name": "Melinda Havadi", "email": "meli.havadi@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocLqEqMxoHpiRxB2xXUERY0AGQ9GVt4O2ngOAG5SsJoZqU1GGs-anA=s96-c", "full_name": "Melinda Havadi", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocLqEqMxoHpiRxB2xXUERY0AGQ9GVt4O2ngOAG5SsJoZqU1GGs-anA=s96-c", "provider_id": "109207201963727215313", "email_verified": true, "phone_verified": false}', NULL, '2025-05-21 08:30:30.669777+00', '2025-05-23 12:54:36.33694+00', NULL, NULL, '', '', NULL, '', 0, NULL, '', NULL, false, NULL, false);


--
-- Data for Name: identities; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

INSERT INTO "auth"."identities" ("provider_id", "user_id", "identity_data", "provider", "last_sign_in_at", "created_at", "updated_at", "id") VALUES
	('e2479383-7ba2-4290-beb7-6e8d08b52ee6', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '{"sub": "e2479383-7ba2-4290-beb7-6e8d08b52ee6", "role": "terapeut", "email": "sory.loby@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-04-26 14:27:31.173877+00', '2025-04-26 14:27:31.173938+00', '2025-04-26 14:27:31.173938+00', '70b61e8e-e052-4979-b600-f9866e286a5c'),
	('3497971b-b2c2-4a3a-9a42-420d8a26faec', '3497971b-b2c2-4a3a-9a42-420d8a26faec', '{"sub": "3497971b-b2c2-4a3a-9a42-420d8a26faec", "role": "terapeut", "email": "kis.monica@yahoo.it", "email_verified": true, "phone_verified": false}', 'email', '2025-05-13 08:18:59.05271+00', '2025-05-13 08:18:59.052758+00', '2025-05-13 08:18:59.052758+00', 'a629d463-4b7c-47b5-bb78-353171f6933b'),
	('20d55537-6f54-41d6-98a6-474174099d17', '20d55537-6f54-41d6-98a6-474174099d17', '{"sub": "20d55537-6f54-41d6-98a6-474174099d17", "email": "carmenam_ro@yahoo.com", "email_verified": true, "phone_verified": false, "invited_by_referral_code": "QTB7MTU6"}', 'email', '2025-05-20 21:37:36.164296+00', '2025-05-20 21:37:36.164346+00', '2025-05-20 21:37:36.164346+00', 'faeb5d77-a87d-454a-b6eb-723b84b53cd3'),
	('99556ce6-0304-4614-aeba-0c2f3d73a9f6', '99556ce6-0304-4614-aeba-0c2f3d73a9f6', '{"sub": "99556ce6-0304-4614-aeba-0c2f3d73a9f6", "email": "psiholog.kerteszreka@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-21 07:49:50.800275+00', '2025-05-21 07:49:50.800325+00', '2025-05-21 07:49:50.800325+00', '12e9d5e4-78eb-4d8b-bd64-15b95cc824a8'),
	('df1d2f97-8f64-4160-a909-9039e6619ae3', 'df1d2f97-8f64-4160-a909-9039e6619ae3', '{"sub": "df1d2f97-8f64-4160-a909-9039e6619ae3", "role": "terapeut", "email": "psihologandreeadianaion@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-13 07:49:31.679439+00', '2025-05-13 07:49:31.679503+00', '2025-05-13 07:49:31.679503+00', '8c65fe45-3f1a-4d71-b086-834ab1d6b8ac'),
	('e9af8519-44db-48ee-9e9d-b7fe14ccc7a5', 'e9af8519-44db-48ee-9e9d-b7fe14ccc7a5', '{"sub": "e9af8519-44db-48ee-9e9d-b7fe14ccc7a5", "email": "izabella.cete@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-21 11:46:12.356681+00', '2025-05-21 11:46:12.356729+00', '2025-05-21 11:46:12.356729+00', '590066db-f546-48d5-a6a6-15cc1378c286'),
	('ae0309b5-4017-4d32-9b5b-74d2f0323837', 'ae0309b5-4017-4d32-9b5b-74d2f0323837', '{"sub": "ae0309b5-4017-4d32-9b5b-74d2f0323837", "role": "terapeut", "email": "sory.loby2@gmail.com", "email_verified": false, "phone_verified": false}', 'email', '2025-05-07 00:41:00.220256+00', '2025-05-07 00:41:00.220334+00', '2025-05-07 00:41:00.220334+00', '961a5204-682b-40d7-8fda-6eb1f5512c96'),
	('8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8', '8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8', '{"sub": "8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8", "email": "adryma2016@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-19 14:52:44.299074+00', '2025-05-19 14:52:44.299122+00', '2025-05-19 14:52:44.299122+00', '02eefa8b-40dd-4621-af01-cecf9048e745'),
	('cf18dae6-9d04-4fa7-b284-f4ef1164a1ef', 'cf18dae6-9d04-4fa7-b284-f4ef1164a1ef', '{"sub": "cf18dae6-9d04-4fa7-b284-f4ef1164a1ef", "role": "client", "email": "gorjy.ghy@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-07 07:29:44.822309+00', '2025-05-07 07:29:44.822403+00', '2025-05-07 07:29:44.822403+00', 'e749ff1f-a775-4224-998c-6a2184b666a8'),
	('d0c25236-c4c4-4621-90a1-51f5f4d22d2b', 'd0c25236-c4c4-4621-90a1-51f5f4d22d2b', '{"sub": "d0c25236-c4c4-4621-90a1-51f5f4d22d2b", "email": "carmen.talan@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-15 17:55:54.469844+00', '2025-05-15 17:55:54.469898+00', '2025-05-15 17:55:54.469898+00', 'a2197e62-8655-45ed-9be7-899a142a6df0'),
	('100838435522069587668', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', '{"iss": "https://accounts.google.com", "sub": "100838435522069587668", "name": "Denisa Romanică", "email": "romanica.denisa@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocLXEZRllPZxwAlV6wIKZ42bnbx7zVnM4xlKrTGL0dcOVMsZLw=s96-c", "full_name": "Denisa Romanică", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocLXEZRllPZxwAlV6wIKZ42bnbx7zVnM4xlKrTGL0dcOVMsZLw=s96-c", "provider_id": "100838435522069587668", "email_verified": true, "phone_verified": false}', 'google', '2025-05-13 08:06:36.856049+00', '2025-05-13 08:06:36.856113+00', '2025-05-13 08:06:36.856113+00', '71da5d17-8ac2-40ca-a198-01eb4e688393'),
	('aa3c7129-7b21-49e5-b099-19fa2ef0c95f', 'aa3c7129-7b21-49e5-b099-19fa2ef0c95f', '{"sub": "aa3c7129-7b21-49e5-b099-19fa2ef0c95f", "role": "terapeut", "email": "amaliacosma@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-13 08:19:48.399635+00', '2025-05-13 08:19:48.399695+00', '2025-05-13 08:19:48.399695+00', 'c56e9ea5-0ae9-480d-b185-4638f3205b8d'),
	('106484611114442117643', 'aa3c7129-7b21-49e5-b099-19fa2ef0c95f', '{"iss": "https://accounts.google.com", "sub": "106484611114442117643", "name": "Amalia Tamas", "email": "amaliacosma@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocIJnWj2URzkZgrS5-Ag26bF3iYhiWsC2q1zmtd8ffhUmcBwSlGeOw=s96-c", "full_name": "Amalia Tamas", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocIJnWj2URzkZgrS5-Ag26bF3iYhiWsC2q1zmtd8ffhUmcBwSlGeOw=s96-c", "provider_id": "106484611114442117643", "email_verified": true, "phone_verified": false}', 'google', '2025-05-13 08:25:05.005473+00', '2025-05-13 08:25:05.00556+00', '2025-05-13 08:25:05.00556+00', 'c3050dc1-2a5b-428d-8d4c-565214596b0b'),
	('107883845136753509499', '98daacc7-a021-4869-b7d3-33599178f966', '{"iss": "https://accounts.google.com", "sub": "107883845136753509499", "name": "Laura Mera", "email": "laura.mera1128@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocKfuqWJGKt6nJa1rZnooKD7eieIIjRQuWgxX16u9J5ppd6h0w=s96-c", "full_name": "Laura Mera", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocKfuqWJGKt6nJa1rZnooKD7eieIIjRQuWgxX16u9J5ppd6h0w=s96-c", "provider_id": "107883845136753509499", "email_verified": true, "phone_verified": false}', 'google', '2025-05-22 06:54:03.045115+00', '2025-05-22 06:54:03.045173+00', '2025-05-22 06:54:03.045173+00', '9ad9c972-0dc6-4e70-89b7-e04581441b26'),
	('101645265700727560830', 'e1ca682f-8dd7-4399-b622-4408513c1c11', '{"iss": "https://accounts.google.com", "sub": "101645265700727560830", "name": "Adriana Știube", "email": "psiho.adrianastiube@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocKghYhgHvcyjW7iUHcp3QN1t9-ff0Hcs15i1NA93Va13qbpKIk=s96-c", "full_name": "Adriana Știube", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocKghYhgHvcyjW7iUHcp3QN1t9-ff0Hcs15i1NA93Va13qbpKIk=s96-c", "provider_id": "101645265700727560830", "email_verified": true, "phone_verified": false}', 'google', '2025-05-13 09:32:59.590942+00', '2025-05-13 09:32:59.590993+00', '2025-05-13 09:32:59.590993+00', 'f3dd24eb-fad8-42db-909e-a85dd5668a6b'),
	('49af0fde-1e09-4899-85d0-42f87dc62ad7', '49af0fde-1e09-4899-85d0-42f87dc62ad7', '{"sub": "49af0fde-1e09-4899-85d0-42f87dc62ad7", "email": "mihocbogdan96@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-16 08:24:19.30315+00', '2025-05-16 08:24:19.303205+00', '2025-05-16 08:24:19.303205+00', 'ec649cee-f705-44ea-892d-64571842319a'),
	('111736287324672843371', '3a317800-976d-4277-a491-27d7962bb16b', '{"iss": "https://accounts.google.com", "sub": "111736287324672843371", "name": "Alexandru Suciaghi", "email": "suciaghialex@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocJ5N61hhK8Uh223mxMwBr4MsUf7-6ZQaMdFTHJ4do9KMxbJ3G4=s96-c", "full_name": "Alexandru Suciaghi", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocJ5N61hhK8Uh223mxMwBr4MsUf7-6ZQaMdFTHJ4do9KMxbJ3G4=s96-c", "provider_id": "111736287324672843371", "email_verified": true, "phone_verified": false}', 'google', '2025-05-21 15:26:30.653229+00', '2025-05-21 15:26:30.653293+00', '2025-05-22 15:19:58.04744+00', 'f7fed3f8-2b08-4e39-9ea8-efd7f9d7bafc'),
	('89b950c9-a55e-4747-abf4-e403523289d4', '89b950c9-a55e-4747-abf4-e403523289d4', '{"sub": "89b950c9-a55e-4747-abf4-e403523289d4", "role": "terapeut", "email": "iulia0475@gmail.com", "email_verified": false, "phone_verified": false}', 'email', '2025-05-13 10:07:13.476223+00', '2025-05-13 10:07:13.476271+00', '2025-05-13 10:07:13.476271+00', '84bbbcc6-140b-4ed6-9a40-537e4447a461'),
	('a830c1a7-13ce-4c8f-96fa-4c7c7bb4085e', 'a830c1a7-13ce-4c8f-96fa-4c7c7bb4085e', '{"sub": "a830c1a7-13ce-4c8f-96fa-4c7c7bb4085e", "role": "terapeut", "email": "alexandru_georgian09@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-13 11:28:43.183769+00', '2025-05-13 11:28:43.183828+00', '2025-05-13 11:28:43.183828+00', '4f9f7093-94fe-4ddf-867e-b2a78cb8ee03'),
	('101090285835352151677', 'c07e8742-9b26-4257-80d8-81ea920e3722', '{"iss": "https://accounts.google.com", "sub": "101090285835352151677", "name": "Cristina Buzea", "email": "cbuzea30@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocJBXiByUZ_l6CHaMswX2Mad1mGAzV1LKIC4hKjboET6xCJn80yx=s96-c", "full_name": "Cristina Buzea", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocJBXiByUZ_l6CHaMswX2Mad1mGAzV1LKIC4hKjboET6xCJn80yx=s96-c", "provider_id": "101090285835352151677", "email_verified": true, "phone_verified": false}', 'google', '2025-05-13 18:37:38.49671+00', '2025-05-13 18:37:38.496771+00', '2025-05-13 20:01:00.456169+00', 'b8fad6d4-1819-4c23-8d75-4111b4a02a3f'),
	('1e8e19fd-7346-4d83-807e-404c01903baf', '1e8e19fd-7346-4d83-807e-404c01903baf', '{"sub": "1e8e19fd-7346-4d83-807e-404c01903baf", "email": "baciu.raul555@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-20 23:50:00.59445+00', '2025-05-20 23:50:00.594514+00', '2025-05-20 23:50:00.594514+00', 'a8e85ccb-2ca2-42d9-a577-a2b3effe5581'),
	('100284568331088922268', '12389e53-ab41-4ff5-90ee-c3593e2b84cc', '{"iss": "https://accounts.google.com", "sub": "100284568331088922268", "name": "ANDRIESCU DIANA", "email": "andriescu.diana98@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocI_FCZZaXB04Rhye3-DmVq3RFB8GCOnBWmIJBaEuSHgoHwes9dYJg=s96-c", "full_name": "ANDRIESCU DIANA", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocI_FCZZaXB04Rhye3-DmVq3RFB8GCOnBWmIJBaEuSHgoHwes9dYJg=s96-c", "provider_id": "100284568331088922268", "email_verified": true, "phone_verified": false}', 'google', '2025-05-13 15:56:43.182029+00', '2025-05-13 15:56:43.182082+00', '2025-05-14 13:45:20.158467+00', '4ed3f18a-766f-484a-a2ea-fb06e6be7b2d'),
	('5690ddb1-c997-4a3e-895a-06b93dab6ec4', '5690ddb1-c997-4a3e-895a-06b93dab6ec4', '{"sub": "5690ddb1-c997-4a3e-895a-06b93dab6ec4", "email": "pintea.daiana1399@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-21 07:52:05.110889+00', '2025-05-21 07:52:05.111437+00', '2025-05-21 07:52:05.111437+00', 'e02c9611-3fcd-486e-ae12-8b7c80a75502'),
	('f10db344-d6f0-4ae3-8ea0-4b1cb2a80894', 'f10db344-d6f0-4ae3-8ea0-4b1cb2a80894', '{"sub": "f10db344-d6f0-4ae3-8ea0-4b1cb2a80894", "role": "terapeut", "email": "psiholog.denisapopescu@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-14 15:26:57.182656+00', '2025-05-14 15:26:57.182703+00', '2025-05-14 15:26:57.182703+00', 'f2c366a8-30a7-4663-b547-f6218d5b0d4e'),
	('76f53ea1-d6bf-4bf7-b88a-918e4062766e', '76f53ea1-d6bf-4bf7-b88a-918e4062766e', '{"sub": "76f53ea1-d6bf-4bf7-b88a-918e4062766e", "email": "secrets.of.life.f2p@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-14 15:26:28.230264+00', '2025-05-14 15:26:28.230344+00', '2025-05-14 15:26:28.230344+00', 'c09abec0-38f7-435a-9ccb-bf344e7b4ee4'),
	('117161663538106023093', '7733575e-14a6-48a4-bf21-b7901b8d6714', '{"iss": "https://accounts.google.com", "sub": "117161663538106023093", "name": "Alex Suciaghi", "email": "suciaghialexandrushorts@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocKgwFNjoaehEzyQMHWZWj55QyAKPD-uzgq0XbdGdGjzU4fkwg=s96-c", "full_name": "Alex Suciaghi", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocKgwFNjoaehEzyQMHWZWj55QyAKPD-uzgq0XbdGdGjzU4fkwg=s96-c", "provider_id": "117161663538106023093", "email_verified": true, "phone_verified": false}', 'google', '2025-05-15 06:23:30.372665+00', '2025-05-15 06:23:30.37272+00', '2025-05-15 06:23:30.37272+00', '5087320a-2571-47bc-8fa1-d3d6ba2f92de'),
	('433c694d-a26a-44cb-84cc-45f84d7daf07', '433c694d-a26a-44cb-84cc-45f84d7daf07', '{"sub": "433c694d-a26a-44cb-84cc-45f84d7daf07", "email": "camyblaga@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-15 06:35:23.698878+00', '2025-05-15 06:35:23.698932+00', '2025-05-15 06:35:23.698932+00', '189444c3-646e-4fc8-add6-9c88d91e6420'),
	('8e441edf-2d91-4551-a4e6-924316cd2090', '8e441edf-2d91-4551-a4e6-924316cd2090', '{"sub": "8e441edf-2d91-4551-a4e6-924316cd2090", "email": "contactandreigeorge@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-15 06:35:50.188782+00', '2025-05-15 06:35:50.188839+00', '2025-05-15 06:35:50.188839+00', '3bbfa93f-4847-4e22-aeae-ea0896d87c3e'),
	('1d4e4d74-493a-4758-a5e1-3229a81bae5d', '1d4e4d74-493a-4758-a5e1-3229a81bae5d', '{"sub": "1d4e4d74-493a-4758-a5e1-3229a81bae5d", "email": "inna.medeea.lupu@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-15 08:07:38.513205+00', '2025-05-15 08:07:38.513253+00', '2025-05-15 08:07:38.513253+00', 'f8cd75f1-9844-41e7-8d56-69c0c2de8aec'),
	('118205813660254822363', '1375c34c-1b05-438e-8f4f-eeb5f0d373f8', '{"iss": "https://accounts.google.com", "sub": "118205813660254822363", "name": "Valentin Pascariu", "email": "valentinpascariu85@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocKSFTLsU2ZvPBcf6KBdX7f6S9ItM5cIQIQKohsYzb5QBqOl_ATe=s96-c", "full_name": "Valentin Pascariu", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocKSFTLsU2ZvPBcf6KBdX7f6S9ItM5cIQIQKohsYzb5QBqOl_ATe=s96-c", "provider_id": "118205813660254822363", "email_verified": true, "phone_verified": false}', 'google', '2025-05-15 09:53:23.144859+00', '2025-05-15 09:53:23.144909+00', '2025-05-15 09:53:23.144909+00', '4c920e1a-62c2-4f98-8ccf-fb0435b0116d'),
	('07a95865-754b-4fed-ae0a-d4b69c486190', '07a95865-754b-4fed-ae0a-d4b69c486190', '{"sub": "07a95865-754b-4fed-ae0a-d4b69c486190", "email": "carmendadu@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-15 12:21:19.349326+00', '2025-05-15 12:21:19.349378+00', '2025-05-15 12:21:19.349378+00', '42b2945b-f199-4e68-b5a0-05a8d2bccc2e'),
	('f9a83a83-6324-46d1-9e75-3eddf8edd890', 'f9a83a83-6324-46d1-9e75-3eddf8edd890', '{"sub": "f9a83a83-6324-46d1-9e75-3eddf8edd890", "email": "anghelescucodrutvictor@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-15 13:48:04.885823+00', '2025-05-15 13:48:04.885875+00', '2025-05-15 13:48:04.885875+00', '82d77ab8-e5e4-4338-945b-242b0512539e'),
	('109380310264740269446', '6a5e67bb-c9b1-4b30-b860-3e4db36fcf2f', '{"iss": "https://accounts.google.com", "sub": "109380310264740269446", "name": "Mălina Adriana Lazăr", "email": "psiholog.malinalazar@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocJbTBmF5TyrOCEKJ9QzeFKx7WMshDmyIAk-eRYSHLXT_UuV3A=s96-c", "full_name": "Mălina Adriana Lazăr", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocJbTBmF5TyrOCEKJ9QzeFKx7WMshDmyIAk-eRYSHLXT_UuV3A=s96-c", "provider_id": "109380310264740269446", "email_verified": true, "phone_verified": false}', 'google', '2025-05-15 16:04:01.082301+00', '2025-05-15 16:04:01.082353+00', '2025-05-15 16:04:01.082353+00', 'a79cdfc1-bfd8-495e-9805-9e466e4cf89d'),
	('113047692070349041732', 'a7e4662b-0ae7-4687-98f5-a35387a707be', '{"iss": "https://accounts.google.com", "sub": "113047692070349041732", "name": "Angelica Iozsi", "email": "iozsiangelica@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocLlX8FxtNX2KB7LCJ-BOXpJO5PzVlsXp6t8uiLxTtBtKJrJNzaL=s96-c", "full_name": "Angelica Iozsi", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocLlX8FxtNX2KB7LCJ-BOXpJO5PzVlsXp6t8uiLxTtBtKJrJNzaL=s96-c", "provider_id": "113047692070349041732", "email_verified": true, "phone_verified": false}', 'google', '2025-05-15 16:42:14.560566+00', '2025-05-15 16:42:14.56062+00', '2025-05-15 16:42:14.56062+00', 'd929200d-3cb6-4c39-a732-3666c70e829b'),
	('3b53ad8e-8faf-48c0-9628-f49ab70ded79', '3b53ad8e-8faf-48c0-9628-f49ab70ded79', '{"sub": "3b53ad8e-8faf-48c0-9628-f49ab70ded79", "email": "cosmo.coach.aag@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-21 10:38:35.557518+00', '2025-05-21 10:38:35.557582+00', '2025-05-21 10:38:35.557582+00', '2473e521-ba4b-4f02-bf7f-830b9ac5fcb5'),
	('a3c141d5-a60e-4211-99ce-d1828f4174cf', 'a3c141d5-a60e-4211-99ce-d1828f4174cf', '{"sub": "a3c141d5-a60e-4211-99ce-d1828f4174cf", "email": "ggabicoz@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-21 14:01:50.255424+00', '2025-05-21 14:01:50.255482+00', '2025-05-21 14:01:50.255482+00', '9c941833-84ab-48a6-b012-8dfcd6d52ab9'),
	('103869521089619563567', '512c3b3b-0fa0-4659-8c0e-daccd911baa6', '{"iss": "https://accounts.google.com", "sub": "103869521089619563567", "name": "Cătălina Petruș-Pop", "email": "petruspop.catalina@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocIflS6SF0oWEmKgQh966E7yAIWpysoq0xgmp6oziAb1PNgnm6YB=s96-c", "full_name": "Cătălina Petruș-Pop", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocIflS6SF0oWEmKgQh966E7yAIWpysoq0xgmp6oziAb1PNgnm6YB=s96-c", "provider_id": "103869521089619563567", "email_verified": true, "phone_verified": false}', 'google', '2025-05-16 09:10:55.511405+00', '2025-05-16 09:10:55.511462+00', '2025-05-16 09:10:55.511462+00', '3b2361e3-f26c-48fa-9cc4-38c39b92c855'),
	('3bbd94c4-f929-4d5a-9621-721d396f75e3', '3bbd94c4-f929-4d5a-9621-721d396f75e3', '{"sub": "3bbd94c4-f929-4d5a-9621-721d396f75e3", "email": "psih.alinafr@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-16 09:27:39.798935+00', '2025-05-16 09:27:39.799016+00', '2025-05-16 09:27:39.799016+00', '6ade7797-4b70-405d-a712-2f3b0d65b2bb'),
	('c7fc72ce-3614-4d3a-a617-c7b5aa2d9cd0', 'c7fc72ce-3614-4d3a-a617-c7b5aa2d9cd0', '{"sub": "c7fc72ce-3614-4d3a-a617-c7b5aa2d9cd0", "email": "ageorgescu22@yahoo.com", "email_verified": false, "phone_verified": false}', 'email', '2025-05-16 09:42:57.956796+00', '2025-05-16 09:42:57.956845+00', '2025-05-16 09:42:57.956845+00', '25234152-83d1-475d-9161-4122197287bd'),
	('104747477963223972382', '3e6b8532-e559-4bba-a913-9178fdb2a0bd', '{"iss": "https://accounts.google.com", "sub": "104747477963223972382", "name": "Sorina Brif", "email": "brifsorina@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocI-wCDX0_UUtMuxQ3NgVV9tN6gDGm__w4YcGACMcDIp2GXAeQ=s96-c", "full_name": "Sorina Brif", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocI-wCDX0_UUtMuxQ3NgVV9tN6gDGm__w4YcGACMcDIp2GXAeQ=s96-c", "provider_id": "104747477963223972382", "email_verified": true, "phone_verified": false}', 'google', '2025-05-16 10:42:46.601503+00', '2025-05-16 10:42:46.601553+00', '2025-05-16 10:42:46.601553+00', '4732cce7-fa14-4065-b767-b473ea3e0849'),
	('d1792c86-294f-453e-ae1e-8474ab5553e3', 'd1792c86-294f-453e-ae1e-8474ab5553e3', '{"sub": "d1792c86-294f-453e-ae1e-8474ab5553e3", "email": "mihaelastanciu999@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-16 10:42:59.917988+00', '2025-05-16 10:42:59.918033+00', '2025-05-16 10:42:59.918033+00', 'f455cec5-04be-468f-ac52-59783d50c93a'),
	('52514d39-b9bc-42e3-8a24-69cd971a8414', '52514d39-b9bc-42e3-8a24-69cd971a8414', '{"sub": "52514d39-b9bc-42e3-8a24-69cd971a8414", "email": "carmenrauta68@yahoo.com", "email_verified": false, "phone_verified": false}', 'email', '2025-05-16 11:02:28.961998+00', '2025-05-16 11:02:28.962049+00', '2025-05-16 11:02:28.962049+00', '65f6f4e9-efbf-48d8-b193-78144cf2c64b'),
	('13640682-e72c-448d-87a7-af45f1070498', '13640682-e72c-448d-87a7-af45f1070498', '{"sub": "13640682-e72c-448d-87a7-af45f1070498", "email": "vali_robu@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-16 12:24:25.740192+00', '2025-05-16 12:24:25.740245+00', '2025-05-16 12:24:25.740245+00', '85ac9b40-18df-4d04-9dbd-4b10387425a3'),
	('d707eee8-8de6-49fa-a4a6-00d79d6eded8', 'd707eee8-8de6-49fa-a4a6-00d79d6eded8', '{"sub": "d707eee8-8de6-49fa-a4a6-00d79d6eded8", "email": "camelya98@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-16 14:05:20.118801+00', '2025-05-16 14:05:20.118852+00', '2025-05-16 14:05:20.118852+00', '79980a56-2810-4bf3-81c7-14d9ee582a30'),
	('7617e0bf-ca39-47d8-a708-935afb8eaf87', '7617e0bf-ca39-47d8-a708-935afb8eaf87', '{"sub": "7617e0bf-ca39-47d8-a708-935afb8eaf87", "email": "laura_stan80@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-17 05:29:41.062959+00', '2025-05-17 05:29:41.063025+00', '2025-05-17 05:29:41.063025+00', '002e8af4-d856-4a7c-b550-fa7d1651b1ae'),
	('111777482259273280547', '459220a9-338b-4a45-8533-24789a3b1da7', '{"iss": "https://accounts.google.com", "sub": "111777482259273280547", "name": "Miu Simplu", "email": "miusimplu@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocLttJHu6elvoOiw2cmkUjS5oPVJbu7_eZeHqrJaLpaKgcoK-g=s96-c", "full_name": "Miu Simplu", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocLttJHu6elvoOiw2cmkUjS5oPVJbu7_eZeHqrJaLpaKgcoK-g=s96-c", "provider_id": "111777482259273280547", "email_verified": true, "phone_verified": false}', 'google', '2025-05-18 13:24:52.959275+00', '2025-05-18 13:24:52.959334+00', '2025-05-18 13:24:52.959334+00', '2ce1ed51-5f7e-4dc2-b106-474a6209ef10'),
	('9945cd00-d2ba-494d-9852-4d9ceb75258e', '9945cd00-d2ba-494d-9852-4d9ceb75258e', '{"sub": "9945cd00-d2ba-494d-9852-4d9ceb75258e", "email": "lilea.emanuelacristina@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-19 05:57:40.615753+00', '2025-05-19 05:57:40.615806+00', '2025-05-19 05:57:40.615806+00', 'b1b6060b-f6d5-4db2-a009-b341ec5535eb'),
	('23584fae-eae0-4163-9e12-0e8fc3d4047e', '23584fae-eae0-4163-9e12-0e8fc3d4047e', '{"sub": "23584fae-eae0-4163-9e12-0e8fc3d4047e", "email": "geaninabasturescu@gmail.com", "email_verified": true, "phone_verified": false, "invited_by_referral_code": "QTB7MTU6"}', 'email', '2025-05-19 06:00:38.292097+00', '2025-05-19 06:00:38.292173+00', '2025-05-19 06:00:38.292173+00', '9e98eda4-a78a-4a0c-ae4c-f07ab64762b1'),
	('ab84c874-6fed-45be-9e1d-28da0a041149', 'ab84c874-6fed-45be-9e1d-28da0a041149', '{"sub": "ab84c874-6fed-45be-9e1d-28da0a041149", "email": "elenadaniele_popa@yahoo.com", "email_verified": true, "phone_verified": false, "invited_by_referral_code": "QTB7MTU6"}', 'email', '2025-05-19 07:53:38.68769+00', '2025-05-19 07:53:38.687751+00', '2025-05-19 07:53:38.687751+00', 'e9e52b19-19c6-4c80-a26c-6683ceb108c2'),
	('c727ce88-386f-49e6-88c9-df7115e793e5', 'c727ce88-386f-49e6-88c9-df7115e793e5', '{"sub": "c727ce88-386f-49e6-88c9-df7115e793e5", "email": "gianinacornea@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-19 08:07:16.7641+00', '2025-05-19 08:07:16.764147+00', '2025-05-19 08:07:16.764147+00', 'ed7281f1-8974-43f4-8b1e-56b6750ecbae'),
	('3add3342-f74c-49c7-985b-238208eebac5', '3add3342-f74c-49c7-985b-238208eebac5', '{"sub": "3add3342-f74c-49c7-985b-238208eebac5", "email": "terapeutdenisaelena@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-19 08:56:43.554391+00', '2025-05-19 08:56:43.554439+00', '2025-05-19 08:56:43.554439+00', 'e278eae1-3fa2-42b4-801e-c460c26f0803'),
	('a6f658f8-149d-4063-b1d9-c54105f03392', 'a6f658f8-149d-4063-b1d9-c54105f03392', '{"sub": "a6f658f8-149d-4063-b1d9-c54105f03392", "email": "nicoldina1974@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-19 09:41:14.711547+00', '2025-05-19 09:41:14.711603+00', '2025-05-19 09:41:14.711603+00', '5152acd9-03f7-4bbd-ab0c-d5351ab8638f'),
	('53c97092-2634-4c47-ad83-808566dfbdcd', '53c97092-2634-4c47-ad83-808566dfbdcd', '{"sub": "53c97092-2634-4c47-ad83-808566dfbdcd", "email": "psiholog.cristina-avram@outlook.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-19 09:42:38.944278+00', '2025-05-19 09:42:38.944336+00', '2025-05-19 09:42:38.944336+00', 'd0e7df7a-38e1-4267-8c11-6927863d958c'),
	('feea398b-e2c0-4217-be62-0da00ee5ac3b', 'feea398b-e2c0-4217-be62-0da00ee5ac3b', '{"sub": "feea398b-e2c0-4217-be62-0da00ee5ac3b", "email": "complet.definit@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-19 11:58:16.40804+00', '2025-05-19 11:58:16.408093+00', '2025-05-19 11:58:16.408093+00', 'dbb2c0d9-c75d-4c1b-bea7-468f256a1791'),
	('783f639b-1cab-407c-b1a9-fa510c00396d', '783f639b-1cab-407c-b1a9-fa510c00396d', '{"sub": "783f639b-1cab-407c-b1a9-fa510c00396d", "email": "biancanan1979@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-19 14:12:06.78074+00', '2025-05-19 14:12:06.780792+00', '2025-05-19 14:12:06.780792+00', '1480c0c8-4cbe-48ec-aefb-30329cb9c63a'),
	('cae70df8-8ff3-4f34-9d75-dae1732f24a7', 'cae70df8-8ff3-4f34-9d75-dae1732f24a7', '{"sub": "cae70df8-8ff3-4f34-9d75-dae1732f24a7", "email": "lao.water7@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-21 00:15:22.360978+00', '2025-05-21 00:15:22.36103+00', '2025-05-21 00:15:22.36103+00', '2682b904-db0f-4e36-9bbf-df839ff56f98'),
	('65da1664-c0da-4c49-88c8-dce05acc1374', '65da1664-c0da-4c49-88c8-dce05acc1374', '{"sub": "65da1664-c0da-4c49-88c8-dce05acc1374", "email": "hey_anamaria@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-19 14:09:03.716977+00', '2025-05-19 14:09:03.717032+00', '2025-05-19 14:09:03.717032+00', '8477cb02-7bb9-49de-8da1-8756f8442093'),
	('dd8d0335-6696-4fb6-b186-31a0533d9587', 'dd8d0335-6696-4fb6-b186-31a0533d9587', '{"sub": "dd8d0335-6696-4fb6-b186-31a0533d9587", "email": "adrianakarabuber79@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-19 15:10:24.353662+00', '2025-05-19 15:10:24.35371+00', '2025-05-19 15:10:24.35371+00', '889b0b53-546e-469a-908b-7b0a1d66ad6b'),
	('1bc4edd2-b5de-4b77-abb8-ffdad01efa4c', '1bc4edd2-b5de-4b77-abb8-ffdad01efa4c', '{"sub": "1bc4edd2-b5de-4b77-abb8-ffdad01efa4c", "email": "valentinfionut@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-19 15:11:30.340107+00', '2025-05-19 15:11:30.340153+00', '2025-05-19 15:11:30.340153+00', 'bb4f5479-4229-487f-b9dc-56fd37156d40'),
	('3e9a53b2-aefd-4282-b37a-ee95f47dfe77', '3e9a53b2-aefd-4282-b37a-ee95f47dfe77', '{"sub": "3e9a53b2-aefd-4282-b37a-ee95f47dfe77", "email": "violetapal65@gmail.com", "email_verified": true, "phone_verified": false, "invited_by_referral_code": "7AY4HJWK"}', 'email', '2025-05-19 15:43:58.951548+00', '2025-05-19 15:43:58.951598+00', '2025-05-19 15:43:58.951598+00', '3902dc96-8bf0-4bc7-8518-d3701c14ec69'),
	('8d983543-4636-4bce-a1b8-d0d5e9c2f88f', '8d983543-4636-4bce-a1b8-d0d5e9c2f88f', '{"sub": "8d983543-4636-4bce-a1b8-d0d5e9c2f88f", "email": "office@mobilamoll.ro", "email_verified": true, "phone_verified": false}', 'email', '2025-05-19 16:31:07.791284+00', '2025-05-19 16:31:07.791332+00', '2025-05-19 16:31:07.791332+00', 'cec87858-ab73-4898-9960-c19186cdbac5'),
	('117594394786742143446', 'a1e1dcfe-893e-4c00-a4eb-29021630205d', '{"iss": "https://accounts.google.com", "sub": "117594394786742143446", "name": "Raluca Mihaela Alexandru", "email": "ralucamihaela.alexandru1984@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocISa6dLtc83CR2Xkp4TdMo8-2fWTDrfYiupr46sYiTIhHbcgQ=s96-c", "full_name": "Raluca Mihaela Alexandru", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocISa6dLtc83CR2Xkp4TdMo8-2fWTDrfYiupr46sYiTIhHbcgQ=s96-c", "provider_id": "117594394786742143446", "email_verified": true, "phone_verified": false}', 'google', '2025-05-19 17:19:58.573885+00', '2025-05-19 17:19:58.573936+00', '2025-05-19 17:19:58.573936+00', '5f64c227-94b8-4d84-8ae3-004af33828b6'),
	('3a317800-976d-4277-a491-27d7962bb16b', '3a317800-976d-4277-a491-27d7962bb16b', '{"sub": "3a317800-976d-4277-a491-27d7962bb16b", "email": "suciaghialex@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-20 05:30:09.461752+00', '2025-05-20 05:30:09.461804+00', '2025-05-20 05:30:09.461804+00', 'b9d485e9-21fa-4cb5-ae1f-4b71a0d9d11e'),
	('7f541d24-fa47-444f-9ca4-f4f7bc3f4dde', '7f541d24-fa47-444f-9ca4-f4f7bc3f4dde', '{"sub": "7f541d24-fa47-444f-9ca4-f4f7bc3f4dde", "email": "ioanalexandruturcu@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-20 06:09:41.950004+00', '2025-05-20 06:09:41.950065+00', '2025-05-20 06:09:41.950065+00', '5a3baae8-82ff-4892-908b-e9f83fdf8087'),
	('d3275dfe-f4df-44fc-acaa-659e92369e66', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '{"sub": "d3275dfe-f4df-44fc-acaa-659e92369e66", "email": "danutjilavu@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-20 06:34:44.753687+00', '2025-05-20 06:34:44.753736+00', '2025-05-20 06:34:44.753736+00', '74340309-0b29-469f-8b6e-5cae86c9be2f'),
	('104495585733168663899', '622d14e0-2b33-4c8b-81d5-231a707fd100', '{"iss": "https://accounts.google.com", "sub": "104495585733168663899", "name": "Gabriela Pogaci", "email": "pogaci2@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocIAr1GaNSj_Sy_e_yCfsJ0ZZEdLlUCF15KFK6IqiqJzmU3WApE=s96-c", "full_name": "Gabriela Pogaci", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocIAr1GaNSj_Sy_e_yCfsJ0ZZEdLlUCF15KFK6IqiqJzmU3WApE=s96-c", "provider_id": "104495585733168663899", "email_verified": true, "phone_verified": false}', 'google', '2025-05-20 07:02:39.042999+00', '2025-05-20 07:02:39.043054+00', '2025-05-20 07:02:39.043054+00', 'e053001a-c23d-442d-b335-a6c473ca8af6'),
	('117698560013326264927', '072aa24d-bfc3-4b0c-93f2-1435906d8381', '{"iss": "https://accounts.google.com", "sub": "117698560013326264927", "name": "Diana Olivia Simu", "email": "dianasimutm@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocI4g-wzezTB5WIYT1HjaC1NL5i1tKYoPXR1ySXyjUYWlD8BZZoW8Q=s96-c", "full_name": "Diana Olivia Simu", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocI4g-wzezTB5WIYT1HjaC1NL5i1tKYoPXR1ySXyjUYWlD8BZZoW8Q=s96-c", "provider_id": "117698560013326264927", "email_verified": true, "phone_verified": false}', 'google', '2025-05-20 07:34:37.651449+00', '2025-05-20 07:34:37.651508+00', '2025-05-20 07:34:37.651508+00', '37a3342d-11e8-4b2a-b2fa-5a116e541116'),
	('905b3a2e-780e-48f5-b37e-b335d9e97d4a', '905b3a2e-780e-48f5-b37e-b335d9e97d4a', '{"sub": "905b3a2e-780e-48f5-b37e-b335d9e97d4a", "email": "loryidu@yahoo.com", "email_verified": true, "phone_verified": false, "invited_by_referral_code": "7AY4HJWK"}', 'email', '2025-05-19 15:48:15.438027+00', '2025-05-19 15:48:15.438079+00', '2025-05-19 15:48:15.438079+00', '05e342cd-4319-48a0-b58e-267089b65cbe'),
	('ae26134b-38c8-4748-8770-5b73d79cae08', 'ae26134b-38c8-4748-8770-5b73d79cae08', '{"sub": "ae26134b-38c8-4748-8770-5b73d79cae08", "email": "teomury@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-20 11:49:42.501881+00', '2025-05-20 11:49:42.501936+00', '2025-05-20 11:49:42.501936+00', 'ee46cc7e-ee90-4fd0-84cb-1e2256b98d19'),
	('101927015616279710709', '7b00956b-eafb-4d19-aed0-67dad9ab51ee', '{"iss": "https://accounts.google.com", "sub": "101927015616279710709", "name": "Maria Lica", "email": "lica.mara.c02@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocJRGhMX7sPQAicMs-9jWcfU0l96SoKXHegRXXQ0sMWfy5m63Q=s96-c", "full_name": "Maria Lica", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocJRGhMX7sPQAicMs-9jWcfU0l96SoKXHegRXXQ0sMWfy5m63Q=s96-c", "provider_id": "101927015616279710709", "email_verified": true, "phone_verified": false}', 'google', '2025-05-20 12:19:40.692444+00', '2025-05-20 12:19:40.692495+00', '2025-05-20 12:19:40.692495+00', 'e4c637e1-70fa-41fb-80a3-0dcda9955174'),
	('682d23b2-3bb3-4f55-9f23-5b7689983e82', '682d23b2-3bb3-4f55-9f23-5b7689983e82', '{"sub": "682d23b2-3bb3-4f55-9f23-5b7689983e82", "email": "alexandra.pandelea88@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-20 13:30:14.583712+00', '2025-05-20 13:30:14.583762+00', '2025-05-20 13:30:14.583762+00', '0cb99927-b33e-461f-8e8c-9675d24ff479'),
	('cff988c4-74c7-4d89-8ea5-ca57af9c7a7a', 'cff988c4-74c7-4d89-8ea5-ca57af9c7a7a', '{"sub": "cff988c4-74c7-4d89-8ea5-ca57af9c7a7a", "email": "renataiancupsiholog@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-20 15:40:45.434732+00', '2025-05-20 15:40:45.434783+00', '2025-05-20 15:40:45.434783+00', '3b6e5dde-8ba3-479e-bb16-2a85f8f5068d'),
	('1aa4f7e2-f7f1-4b27-a7bd-f2595a5fdfce', '1aa4f7e2-f7f1-4b27-a7bd-f2595a5fdfce', '{"sub": "1aa4f7e2-f7f1-4b27-a7bd-f2595a5fdfce", "email": "d_lupu@ymail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-20 18:42:57.460232+00', '2025-05-20 18:42:57.460301+00', '2025-05-20 18:42:57.460301+00', '27a9fc3a-cb67-459e-a8e5-c162dc193541'),
	('116655270411373041793', '6a70d9b5-4fb8-46f7-975b-5887fd4e47de', '{"iss": "https://accounts.google.com", "sub": "116655270411373041793", "name": "Meri Velciu", "email": "meri.velciu@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocIlMFkvPfnVjp5iphYJFTrtWZKfrteF_o1DvvksyQGuUZpIjaL_=s96-c", "full_name": "Meri Velciu", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocIlMFkvPfnVjp5iphYJFTrtWZKfrteF_o1DvvksyQGuUZpIjaL_=s96-c", "provider_id": "116655270411373041793", "email_verified": true, "phone_verified": false}', 'google', '2025-05-21 07:26:09.519626+00', '2025-05-21 07:26:09.519688+00', '2025-05-21 07:26:09.519688+00', '87f4c914-74d9-4c7c-9754-de80b92a1172'),
	('111848928485748322119', '4240bff7-8190-4157-bc20-1b64f6e24ca8', '{"iss": "https://accounts.google.com", "sub": "111848928485748322119", "name": "hellosuciaghi", "email": "hellosuciaghi@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocL_6jE-fJppyScXhSpxLSsjFQ2XEE-O13zfZnsjRNBzYmwYCQ=s96-c", "full_name": "hellosuciaghi", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocL_6jE-fJppyScXhSpxLSsjFQ2XEE-O13zfZnsjRNBzYmwYCQ=s96-c", "provider_id": "111848928485748322119", "email_verified": true, "phone_verified": false}', 'google', '2025-05-21 08:18:03.752691+00', '2025-05-21 08:18:03.752749+00', '2025-05-21 08:18:03.752749+00', 'a0a8190d-cab5-4adc-9ed2-eb86fab42603'),
	('1f149689-c4dc-412f-8de6-9b25ee804842', '1f149689-c4dc-412f-8de6-9b25ee804842', '{"sub": "1f149689-c4dc-412f-8de6-9b25ee804842", "email": "nutzy_neiconi@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-22 12:43:42.450323+00', '2025-05-22 12:43:42.450385+00', '2025-05-22 12:43:42.450385+00', '7dbd8a0d-57cc-4986-9f75-806eb42611e7'),
	('106061337861431131595', '398915d4-fa9b-430f-acd0-c44c6197221b', '{"iss": "https://accounts.google.com", "sub": "106061337861431131595", "name": "Adriana - Mindful Psychology", "email": "adrianamindful@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocIFrBxsn8JyOUocdRvMthpT6Kv5UUGQx3oekhz_kuS__neULeWq=s96-c", "full_name": "Adriana - Mindful Psychology", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocIFrBxsn8JyOUocdRvMthpT6Kv5UUGQx3oekhz_kuS__neULeWq=s96-c", "provider_id": "106061337861431131595", "email_verified": true, "phone_verified": false}', 'google', '2025-05-22 12:56:47.018162+00', '2025-05-22 12:56:47.018213+00', '2025-05-22 12:56:47.018213+00', '7cb4a1c7-342b-4dc0-9e05-d097532b7e93'),
	('109207201963727215313', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', '{"iss": "https://accounts.google.com", "sub": "109207201963727215313", "name": "Melinda Havadi", "email": "meli.havadi@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocLqEqMxoHpiRxB2xXUERY0AGQ9GVt4O2ngOAG5SsJoZqU1GGs-anA=s96-c", "full_name": "Melinda Havadi", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocLqEqMxoHpiRxB2xXUERY0AGQ9GVt4O2ngOAG5SsJoZqU1GGs-anA=s96-c", "provider_id": "109207201963727215313", "email_verified": true, "phone_verified": false}', 'google', '2025-05-21 08:30:30.681898+00', '2025-05-21 08:30:30.681955+00', '2025-05-22 13:25:41.100539+00', '3bf73873-9e12-4302-b981-6ee2a1e68052'),
	('1bd491bf-3874-47d1-a4ed-0983f63a866e', '1bd491bf-3874-47d1-a4ed-0983f63a866e', '{"sub": "1bd491bf-3874-47d1-a4ed-0983f63a866e", "email": "terapeutholistic.eliseiadam@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-22 13:26:55.568791+00', '2025-05-22 13:26:55.568844+00', '2025-05-22 13:26:55.568844+00', 'b74fa24a-3297-493c-a6dc-30fbad7d7363'),
	('147fcc1b-10f1-4184-9d95-d09505d736fa', '147fcc1b-10f1-4184-9d95-d09505d736fa', '{"sub": "147fcc1b-10f1-4184-9d95-d09505d736fa", "email": "ionutrus231@gmail.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-22 13:45:54.473681+00', '2025-05-22 13:45:54.473732+00', '2025-05-22 13:45:54.473732+00', 'eabddc44-98df-41a9-a0e4-7f8ec57fb8e3'),
	('8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', '{"sub": "8458bab3-1fb1-4eb7-8cad-f555bc58fc8f", "email": "sandu_elena1998@yahoo.com", "email_verified": true, "phone_verified": false}', 'email', '2025-05-22 14:37:27.344649+00', '2025-05-22 14:37:27.344703+00', '2025-05-22 14:37:27.344703+00', 'b0237c39-17a2-4a9b-882c-5cbe5c162984'),
	('de7ba501-a94e-4f86-81b3-0afe662ae8de', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '{"sub": "de7ba501-a94e-4f86-81b3-0afe662ae8de", "email": "dan.magirescu@innercoach.ro", "email_verified": true, "phone_verified": false}', 'email', '2025-05-22 14:55:46.397199+00', '2025-05-22 14:55:46.397252+00', '2025-05-22 14:55:46.397252+00', '0ef07782-d0ee-44f2-b375-272a2ff9f882'),
	('100178659624070148668', '4b6f4102-c588-406c-a091-79dd2485fb81', '{"iss": "https://accounts.google.com", "sub": "100178659624070148668", "name": "Suciaghi Alexandru", "email": "suciaghi97@gmail.com", "picture": "https://lh3.googleusercontent.com/a/ACg8ocLJeFxw6SnATf0wdZDyBDolGgpI3B_ZhIPiEHsCInszsXjkWQ=s96-c", "full_name": "Suciaghi Alexandru", "avatar_url": "https://lh3.googleusercontent.com/a/ACg8ocLJeFxw6SnATf0wdZDyBDolGgpI3B_ZhIPiEHsCInszsXjkWQ=s96-c", "provider_id": "100178659624070148668", "email_verified": true, "phone_verified": false}', 'google', '2025-05-01 16:13:19.543503+00', '2025-05-01 16:13:19.543555+00', '2025-05-22 15:20:40.547033+00', '801c97d8-1481-4981-a6cf-da8ad1ad6446');


--
-- Data for Name: instances; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: sessions; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

INSERT INTO "auth"."sessions" ("id", "user_id", "created_at", "updated_at", "factor_id", "aal", "not_after", "refreshed_at", "user_agent", "ip", "tag") VALUES
	('66f300d8-878b-4cf5-a898-17b1b137522b', '13640682-e72c-448d-87a7-af45f1070498', '2025-05-16 12:30:27.466843+00', '2025-05-16 12:30:27.466843+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '82.210.162.248', NULL),
	('f9170fb9-b15b-44b3-b63e-46d8f33b5ea5', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', '2025-05-13 08:06:36.868003+00', '2025-05-17 10:38:56.586521+00', NULL, 'aal1', NULL, '2025-05-17 10:38:56.586449', 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36', '46.97.169.230', NULL),
	('316fa05c-520e-4c52-b322-54a7c8ba7a8c', '98daacc7-a021-4869-b7d3-33599178f966', '2025-05-22 06:54:03.071027+00', '2025-05-22 06:54:03.071027+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '80.96.5.67', NULL),
	('459311de-9991-4c6b-9953-c656eaee24ee', 'f9a83a83-6324-46d1-9e75-3eddf8edd890', '2025-05-15 13:48:19.410842+00', '2025-05-17 07:10:28.111179+00', NULL, 'aal1', NULL, '2025-05-17 07:10:28.1111', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:138.0) Gecko/20100101 Firefox/138.0', '79.115.136.66', NULL),
	('08dc69c3-11ab-4cc5-9519-c879b78550f9', '1d4e4d74-493a-4758-a5e1-3229a81bae5d', '2025-05-15 08:20:41.395562+00', '2025-05-20 05:38:37.004036+00', NULL, 'aal1', NULL, '2025-05-20 05:38:37.003942', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36 Edg/136.0.0.0', '86.120.225.72', NULL),
	('a450173a-f198-4593-b580-1df904cd836c', '8e441edf-2d91-4551-a4e6-924316cd2090', '2025-05-15 06:36:21.745324+00', '2025-05-20 07:48:59.60872+00', NULL, 'aal1', NULL, '2025-05-20 07:48:59.608651', 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '188.27.132.141', NULL),
	('94a65a62-2c00-4d10-a74e-1702f4c3ad92', 'c07e8742-9b26-4257-80d8-81ea920e3722', '2025-05-13 18:37:38.504781+00', '2025-05-20 07:43:51.17803+00', NULL, 'aal1', NULL, '2025-05-20 07:43:51.177952', 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '86.124.25.217', NULL),
	('794ffe94-501d-4cbf-a4e7-0b07b8830fff', '1bd491bf-3874-47d1-a4ed-0983f63a866e', '2025-05-22 13:37:19.095287+00', '2025-05-23 11:33:56.352493+00', NULL, 'aal1', NULL, '2025-05-23 11:33:56.352421', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:138.0) Gecko/20100101 Firefox/138.0', '84.232.202.138', NULL),
	('c0ab9c4e-d642-4be9-ade8-fd917091c32f', 'a830c1a7-13ce-4c8f-96fa-4c7c7bb4085e', '2025-05-13 11:29:32.751194+00', '2025-05-13 11:29:32.751194+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1', '82.78.232.87', NULL),
	('e03313ee-dca4-4e2a-9768-a8cf498accfa', '1375c34c-1b05-438e-8f4f-eeb5f0d373f8', '2025-05-15 09:53:23.155336+00', '2025-05-15 14:27:57.539655+00', NULL, 'aal1', NULL, '2025-05-15 14:27:57.539577', 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/136.0.7103.91 Mobile/15E148 Safari/604.1', '31.94.16.200', NULL),
	('ddb5806f-6794-4b96-a190-6ad7413f391c', '6a5e67bb-c9b1-4b30-b860-3e4db36fcf2f', '2025-05-15 16:04:01.093383+00', '2025-05-15 18:01:05.985177+00', NULL, 'aal1', NULL, '2025-05-15 18:01:05.9851', 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '86.123.132.175', NULL),
	('9a2b936a-f664-4cf3-8462-43dd38b1d17c', 'df1d2f97-8f64-4160-a909-9039e6619ae3', '2025-05-13 07:51:44.607725+00', '2025-05-13 07:51:44.607725+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36', '109.166.131.128', NULL),
	('6ee09707-90f7-41bd-bc89-de70d8c140c4', 'df1d2f97-8f64-4160-a909-9039e6619ae3', '2025-05-13 08:15:14.667943+00', '2025-05-13 08:15:14.667943+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36', '109.166.131.128', NULL),
	('12df7b72-67e7-44dd-84b9-2e7a153f8fdf', '3497971b-b2c2-4a3a-9a42-420d8a26faec', '2025-05-13 08:19:08.556508+00', '2025-05-13 08:19:08.556508+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1', '185.53.196.128', NULL),
	('50ca82d8-f931-4c9e-b438-946168eed8f7', 'aa3c7129-7b21-49e5-b099-19fa2ef0c95f', '2025-05-13 08:23:24.355296+00', '2025-05-13 08:23:24.355296+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/28.0 Chrome/130.0.0.0 Mobile Safari/537.36', '86.120.154.66', NULL),
	('5f003847-1226-40b9-a880-bbcf326ecf3b', 'aa3c7129-7b21-49e5-b099-19fa2ef0c95f', '2025-05-13 08:25:05.011108+00', '2025-05-13 08:25:05.011108+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/28.0 Chrome/130.0.0.0 Mobile Safari/537.36', '86.120.154.66', NULL),
	('d58c4f84-25d2-49a7-b46a-29eca498d440', 'e1ca682f-8dd7-4399-b622-4408513c1c11', '2025-05-13 09:32:59.599948+00', '2025-05-13 09:32:59.599948+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 13; SM-A715F Build/TP1A.220624.014; ) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/135.0.7049.113 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/506.0.0.61.109;]', '86.124.123.171', NULL),
	('49f11184-34d7-4f26-833c-c7cb2cccd277', 'f10db344-d6f0-4ae3-8ea0-4b1cb2a80894', '2025-05-14 15:29:53.104907+00', '2025-05-14 17:39:50.883332+00', NULL, 'aal1', NULL, '2025-05-14 17:39:50.883255', 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1', '86.126.173.218', NULL),
	('2cbd356d-32a1-4f26-b629-7becd4f1a9ae', '12389e53-ab41-4ff5-90ee-c3593e2b84cc', '2025-05-13 15:56:43.196765+00', '2025-05-13 17:26:12.785787+00', NULL, 'aal1', NULL, '2025-05-13 17:26:12.785705', 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1', '188.24.126.195', NULL),
	('b6b1fbcd-527c-4ecb-8759-803efee5899c', 'c07e8742-9b26-4257-80d8-81ea920e3722', '2025-05-13 20:01:00.466158+00', '2025-05-13 20:01:00.466158+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '82.76.86.62', NULL),
	('3f4cc34c-a7ea-4341-8d09-6a8cacc30312', '07a95865-754b-4fed-ae0a-d4b69c486190', '2025-05-15 12:21:29.352266+00', '2025-05-15 12:21:29.352266+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:138.0) Gecko/20100101 Firefox/138.0', '81.196.86.210', NULL),
	('51eca341-e477-4bb3-8853-b41ab3e45299', '3bbd94c4-f929-4d5a-9621-721d396f75e3', '2025-05-16 09:28:24.845356+00', '2025-05-16 09:28:24.845356+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '109.166.129.86', NULL),
	('103694e6-f88f-4d20-8d62-6d96fe6d20dd', '12389e53-ab41-4ff5-90ee-c3593e2b84cc', '2025-05-14 13:45:20.169258+00', '2025-05-14 13:45:20.169258+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36 Edg/136.0.0.0', '188.24.126.195', NULL),
	('dd2d0142-41af-4ab9-8e60-3062574ba56e', 'f10db344-d6f0-4ae3-8ea0-4b1cb2a80894', '2025-05-14 15:29:28.352849+00', '2025-05-14 15:29:28.352849+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1', '178.138.34.125', NULL),
	('f41fafae-c176-4768-a44e-4bac5dda8310', '07a95865-754b-4fed-ae0a-d4b69c486190', '2025-05-15 13:06:21.692017+00', '2025-05-15 13:06:21.692017+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:138.0) Gecko/20100101 Firefox/138.0', '81.196.86.210', NULL),
	('0f927948-a352-4073-b9bb-d6206dbc23df', '433c694d-a26a-44cb-84cc-45f84d7daf07', '2025-05-15 06:35:52.218793+00', '2025-05-15 06:35:52.218793+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '82.78.7.125', NULL),
	('3c54aa4b-8d8e-489f-83e9-ce3909101272', '433c694d-a26a-44cb-84cc-45f84d7daf07', '2025-05-15 07:12:49.632715+00', '2025-05-15 07:12:49.632715+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '82.78.7.125', NULL),
	('906e0dba-d039-4ca1-888d-a57c5d8b49e9', '1d4e4d74-493a-4758-a5e1-3229a81bae5d', '2025-05-15 08:09:35.087506+00', '2025-05-15 08:09:35.087506+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '82.79.226.45', NULL),
	('b762de05-e286-4dcc-8e88-71f22d08313d', 'a7e4662b-0ae7-4687-98f5-a35387a707be', '2025-05-15 16:42:14.566656+00', '2025-05-15 16:42:14.566656+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/27.0 Chrome/125.0.0.0 Mobile Safari/537.36', '185.53.199.48', NULL),
	('cf63c8aa-51f4-43c9-a61e-c7384fbcc836', 'd0c25236-c4c4-4621-90a1-51f5f4d22d2b', '2025-05-15 17:56:19.998424+00', '2025-05-15 17:56:19.998424+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1', '86.120.238.116', NULL),
	('c2b3ae3b-1a17-433c-a55b-c9d702d90ba9', '49af0fde-1e09-4899-85d0-42f87dc62ad7', '2025-05-16 08:24:56.560099+00', '2025-05-16 08:24:56.560099+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 15; SM-S928B Build/AP3A.240905.015.A2; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/136.0.7103.60 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/506.0.0.61.109;]', '82.79.141.38', NULL),
	('c0601f62-c786-45d9-939a-00500578066f', '512c3b3b-0fa0-4659-8c0e-daccd911baa6', '2025-05-16 09:10:55.519715+00', '2025-05-16 09:10:55.519715+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '188.27.128.90', NULL),
	('47b3c558-8ba6-48e2-933d-00cd06d5ffb2', 'd0c25236-c4c4-4621-90a1-51f5f4d22d2b', '2025-05-16 08:53:19.928822+00', '2025-05-16 09:51:43.147084+00', NULL, 'aal1', NULL, '2025-05-16 09:51:43.147009', 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [LinkedInApp]/9.31.1195', '5.2.178.84', NULL),
	('920050d6-5fe6-423e-9319-562ccccc82b6', 'd0c25236-c4c4-4621-90a1-51f5f4d22d2b', '2025-05-16 09:56:30.820638+00', '2025-05-16 09:56:30.820638+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '5.2.178.84', NULL),
	('3abdcec9-29fa-457e-8b23-3e6c05dc04df', 'd1792c86-294f-453e-ae1e-8474ab5553e3', '2025-05-16 10:43:17.049308+00', '2025-05-16 10:43:17.049308+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1', '86.124.88.38', NULL),
	('af02a767-a75c-4304-bd24-4a574a27423f', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '2025-05-20 06:35:10.151355+00', '2025-05-23 07:06:08.132873+00', NULL, 'aal1', NULL, '2025-05-23 07:06:08.132783', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '86.120.178.138', NULL),
	('f545194b-a053-4cac-acba-2f355bff1c22', 'd707eee8-8de6-49fa-a4a6-00d79d6eded8', '2025-05-16 14:06:31.836769+00', '2025-05-16 14:06:31.836769+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/136.0.7103.91 Mobile/15E148 Safari/604.1', '86.125.237.171', NULL),
	('a8555e80-4b5d-4943-8323-d1acefd81ce3', 'd707eee8-8de6-49fa-a4a6-00d79d6eded8', '2025-05-17 07:08:52.913722+00', '2025-05-22 11:41:23.046692+00', NULL, 'aal1', NULL, '2025-05-22 11:41:23.046616', 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/22B91 Instagram 380.0.0.30.73 (iPhone16,2; iOS 18_1_1; ro_RO; ro; scale=3.00; 1290x2796; IABMV/1; 732588223)', '109.166.128.119', NULL),
	('bae30887-77a0-4f55-8df7-71a23a863d22', '8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8', '2025-05-19 14:53:16.860438+00', '2025-05-22 13:20:04.888486+00', NULL, 'aal1', NULL, '2025-05-22 13:20:04.888416', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '192.33.249.102', NULL),
	('bcb1f05a-0a18-4e49-a6c5-e8b5835d1920', '53c97092-2634-4c47-ad83-808566dfbdcd', '2025-05-19 09:42:54.745202+00', '2025-05-19 09:42:54.745202+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '188.24.151.12', NULL),
	('4925c9d2-6710-4bad-9a0a-96ce7ad7deb0', '49af0fde-1e09-4899-85d0-42f87dc62ad7', '2025-05-16 08:24:36.218833+00', '2025-05-17 18:12:26.665019+00', NULL, 'aal1', NULL, '2025-05-17 18:12:26.664947', 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '82.79.141.38', NULL),
	('8ce392c9-ae15-4388-bff0-33a3b65e8b92', '7617e0bf-ca39-47d8-a708-935afb8eaf87', '2025-05-17 05:30:31.775693+00', '2025-05-17 05:30:31.775693+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '213.233.85.238', NULL),
	('c88b12bd-d8bf-4197-a537-bfbb2c384287', '13640682-e72c-448d-87a7-af45f1070498', '2025-05-16 18:28:24.975764+00', '2025-05-17 19:08:57.743393+00', NULL, 'aal1', NULL, '2025-05-17 19:08:57.743313', 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/28.0 Chrome/130.0.0.0 Mobile Safari/537.36', '82.76.159.233', NULL),
	('3d033187-09c8-45ab-b329-0caecc9402e6', 'ab84c874-6fed-45be-9e1d-28da0a041149', '2025-05-19 07:53:58.134358+00', '2025-05-19 11:39:44.364741+00', NULL, 'aal1', NULL, '2025-05-19 11:39:44.364648', 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '197.167.197.190', NULL),
	('56fd5de2-49ce-4664-a2d3-f7032a34e3df', 'a6f658f8-149d-4063-b1d9-c54105f03392', '2025-05-19 09:41:32.138008+00', '2025-05-19 10:39:44.107281+00', NULL, 'aal1', NULL, '2025-05-19 10:39:44.107201', 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/28.0 Chrome/130.0.0.0 Mobile Safari/537.36', '86.124.127.3', NULL),
	('946276b8-71b9-47b8-a754-ae1d98bb881b', 'd707eee8-8de6-49fa-a4a6-00d79d6eded8', '2025-05-19 09:32:20.435857+00', '2025-05-19 11:02:26.499859+00', NULL, 'aal1', NULL, '2025-05-19 11:02:26.499783', 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/136.0.7103.91 Mobile/15E148 Safari/604.1', '86.125.237.171', NULL),
	('7744a0fe-a2e4-4c96-8043-9bdb942b0d57', '9945cd00-d2ba-494d-9852-4d9ceb75258e', '2025-05-19 05:57:49.9312+00', '2025-05-19 05:57:49.9312+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1', '82.78.167.6', NULL),
	('db635967-91eb-46c7-bdd3-099a60531dc2', '49af0fde-1e09-4899-85d0-42f87dc62ad7', '2025-05-16 19:43:13.594379+00', '2025-05-18 09:33:13.648071+00', NULL, 'aal1', NULL, '2025-05-18 09:33:13.647982', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '82.79.141.38', NULL),
	('d52dce43-a6de-4c02-a703-883ee05da527', '23584fae-eae0-4163-9e12-0e8fc3d4047e', '2025-05-19 06:01:06.651924+00', '2025-05-19 06:01:06.651924+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '213.233.88.95', NULL),
	('3cead16c-27ca-41df-8a62-e7c73ae21058', '459220a9-338b-4a45-8533-24789a3b1da7', '2025-05-18 13:24:52.978478+00', '2025-05-18 13:24:52.978478+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '188.24.111.215', NULL),
	('9d3c5a38-e1e6-4ba3-8fd1-ed4b5371c6ed', '7617e0bf-ca39-47d8-a708-935afb8eaf87', '2025-05-19 05:01:04.943631+00', '2025-05-19 06:45:01.307295+00', NULL, 'aal1', NULL, '2025-05-19 06:45:01.307219', 'Mozilla/5.0 (Linux; Android 15; SM-S926B Build/AP3A.240905.015.A2; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/136.0.7103.125 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/507.0.0.55.109;]', '82.76.50.125', NULL),
	('8b5c3680-974c-40ec-8191-9700685d8f31', 'c727ce88-386f-49e6-88c9-df7115e793e5', '2025-05-19 08:08:05.824406+00', '2025-05-19 08:08:05.824406+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '62.231.103.12', NULL),
	('191ee938-d9e8-4917-9295-e9daf83c85e9', '3add3342-f74c-49c7-985b-238208eebac5', '2025-05-19 08:57:17.588714+00', '2025-05-19 08:57:17.588714+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '86.184.49.141', NULL),
	('a44b6d2f-7999-4481-942f-328ac2f0466a', '3add3342-f74c-49c7-985b-238208eebac5', '2025-05-19 08:57:38.074289+00', '2025-05-19 08:57:38.074289+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '86.184.49.141', NULL),
	('e6411bbf-382d-4ac7-a800-d88b0ffbd955', 'a1e1dcfe-893e-4c00-a4eb-29021630205d', '2025-05-19 17:19:58.585539+00', '2025-05-19 17:19:58.585539+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '86.124.163.127', NULL),
	('93a00681-fc65-41fc-b767-a3b5fd788947', '783f639b-1cab-407c-b1a9-fa510c00396d', '2025-05-19 14:12:45.66063+00', '2025-05-19 14:12:45.66063+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '79.119.211.196', NULL),
	('5c9915c1-e1b2-41ec-93c4-c70c76b35331', 'feea398b-e2c0-4217-be62-0da00ee5ac3b', '2025-05-19 11:59:14.682416+00', '2025-05-19 15:10:07.845517+00', NULL, 'aal1', NULL, '2025-05-19 15:10:07.845444', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:138.0) Gecko/20100101 Firefox/138.0', '95.76.17.10', NULL),
	('d0c378ec-b230-471a-a827-20f36286feef', '1bc4edd2-b5de-4b77-abb8-ffdad01efa4c', '2025-05-19 15:12:24.384945+00', '2025-05-19 15:12:24.384945+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/28.0 Chrome/130.0.0.0 Safari/537.36', '83.137.6.190', NULL),
	('4352f66b-0063-4a46-9eb1-453aeb2fc628', '3e9a53b2-aefd-4282-b37a-ee95f47dfe77', '2025-05-19 15:44:27.351002+00', '2025-05-19 15:44:27.351002+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '82.79.219.148', NULL),
	('11edc8b1-40dd-4695-a105-7962c47b6904', '8d983543-4636-4bce-a1b8-d0d5e9c2f88f', '2025-05-19 16:36:04.021612+00', '2025-05-19 17:34:53.767523+00', NULL, 'aal1', NULL, '2025-05-19 17:34:53.767449', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '86.124.47.251', NULL),
	('ca85e05b-2f05-49d5-959b-badbe803ff18', '072aa24d-bfc3-4b0c-93f2-1435906d8381', '2025-05-20 07:34:37.664948+00', '2025-05-21 11:54:11.125834+00', NULL, 'aal1', NULL, '2025-05-21 11:54:11.125761', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36', '128.127.119.44', NULL),
	('b4f78ab9-c351-46f4-87b3-ec8bb5c7ee81', '7f541d24-fa47-444f-9ca4-f4f7bc3f4dde', '2025-05-20 06:34:37.331411+00', '2025-05-20 14:10:19.013121+00', NULL, 'aal1', NULL, '2025-05-20 14:10:19.013037', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '82.76.169.215', NULL),
	('4212a770-de9c-4c96-9524-9552e73a438d', '622d14e0-2b33-4c8b-81d5-231a707fd100', '2025-05-20 07:02:39.057988+00', '2025-05-20 08:00:56.663014+00', NULL, 'aal1', NULL, '2025-05-20 08:00:56.662942', 'Mozilla/5.0 (Linux; Android 11; SM-A705FN Build/RP1A.200720.012; ) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/136.0.7103.112 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/513.1.0.66.92;IABMV/1;]', '46.97.41.150', NULL),
	('925eaaa4-cb49-4e6f-b885-a13d6781e4c0', '3e6b8532-e559-4bba-a913-9178fdb2a0bd', '2025-05-16 10:42:46.610544+00', '2025-05-21 17:19:42.669881+00', NULL, 'aal1', NULL, '2025-05-21 17:19:42.669809', 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '46.97.171.41', NULL),
	('a26dca8f-d5e6-45a8-8520-f243eb10a913', 'dd8d0335-6696-4fb6-b186-31a0533d9587', '2025-05-19 15:10:47.21395+00', '2025-05-21 12:34:06.735142+00', NULL, 'aal1', NULL, '2025-05-21 12:34:06.735064', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1.1 Safari/605.1.15', '78.96.80.85', NULL),
	('a7f322c0-459b-4321-b118-84fc47b47199', '905b3a2e-780e-48f5-b37e-b335d9e97d4a', '2025-05-20 07:47:56.405071+00', '2025-05-20 07:47:56.405071+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '213.177.16.230', NULL),
	('a4517b94-8751-4e39-bcdd-f31911dca337', 'ae26134b-38c8-4748-8770-5b73d79cae08', '2025-05-20 11:49:51.646112+00', '2025-05-20 11:49:51.646112+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1', '82.77.154.162', NULL),
	('06023b23-d51a-41a3-82c3-8ce19fbb1cf2', 'ae26134b-38c8-4748-8770-5b73d79cae08', '2025-05-20 11:50:33.879976+00', '2025-05-20 11:50:33.879976+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1', '82.77.154.162', NULL),
	('a572c723-fa27-4930-8265-f1473a83363d', '7b00956b-eafb-4d19-aed0-67dad9ab51ee', '2025-05-20 12:19:40.702834+00', '2025-05-20 13:23:38.365424+00', NULL, 'aal1', NULL, '2025-05-20 13:23:38.365346', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '188.27.130.253', NULL),
	('7d7c5fe6-c293-4425-befb-be39a959f40c', '1f149689-c4dc-412f-8de6-9b25ee804842', '2025-05-22 13:07:33.929666+00', '2025-05-22 13:07:33.929666+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '86.124.137.241', NULL),
	('c8717aa5-f3bd-43b9-a844-d4ed57e3586e', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', '2025-05-21 08:30:30.696787+00', '2025-05-22 13:21:57.118007+00', NULL, 'aal1', NULL, '2025-05-22 13:21:57.117927', 'Mozilla/5.0 (Linux; Android 14; SM-G991B Build/UP1A.231005.007; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/136.0.7103.125 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/507.0.0.55.109;]', '89.137.114.18', NULL),
	('c23b655d-ccf7-4822-8c80-6e03f1040417', '1bd491bf-3874-47d1-a4ed-0983f63a866e', '2025-05-22 13:28:23.488056+00', '2025-05-22 13:28:23.488056+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '84.232.202.138', NULL),
	('f82aef57-d326-4c95-b973-235d39e1f901', '65da1664-c0da-4c49-88c8-dce05acc1374', '2025-05-22 07:43:42.384152+00', '2025-05-22 11:09:37.772566+00', NULL, 'aal1', NULL, '2025-05-22 11:09:37.772486', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36', '188.27.128.24', NULL),
	('3e483ee1-b0a2-4672-abc8-5761e93bc112', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '2025-05-23 11:39:41.113376+00', '2025-05-23 11:39:41.113376+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/136.0.7103.91 Mobile/15E148 Safari/604.1', '82.78.233.166', NULL),
	('2ab0d612-6842-4ff0-bf3c-e9f556d9bd15', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', '2025-05-22 14:37:53.972417+00', '2025-05-22 14:37:53.972417+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '82.76.93.117', NULL),
	('0c20e12f-0846-409a-8b12-e8e9ea8a714f', 'cff988c4-74c7-4d89-8ea5-ca57af9c7a7a', '2025-05-20 15:40:54.514255+00', '2025-05-20 16:43:21.904352+00', NULL, 'aal1', NULL, '2025-05-20 16:43:21.904278', 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/136.0.7103.91 Mobile/15E148 Safari/604.1', '109.166.131.138', NULL),
	('dcf104b9-9282-45b2-8b89-3c851f0ecf0c', '1aa4f7e2-f7f1-4b27-a7bd-f2595a5fdfce', '2025-05-20 18:43:57.480526+00', '2025-05-20 18:43:57.480526+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/28.0 Chrome/130.0.0.0 Mobile Safari/537.36', '92.180.8.180', NULL),
	('40f37194-b2f8-47dd-ba93-d528922439be', '1aa4f7e2-f7f1-4b27-a7bd-f2595a5fdfce', '2025-05-20 19:34:52.977399+00', '2025-05-20 19:34:52.977399+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Linux; Android 14; SM-S911B Build/UP1A.231005.007; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/136.0.7103.125 Mobile Safari/537.36 [FB_IAB/FB4A;FBAV/507.0.0.55.109;]', '92.180.8.180', NULL),
	('a01c732e-c8ed-4f1b-8c2f-077e47574fda', '1e8e19fd-7346-4d83-807e-404c01903baf', '2025-05-20 23:59:40.854146+00', '2025-05-20 23:59:40.854146+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '81.196.200.213', NULL),
	('c846caf4-9a39-4fe8-8b09-1a4b7a4aa268', '398915d4-fa9b-430f-acd0-c44c6197221b', '2025-05-22 12:56:47.028168+00', '2025-05-22 22:08:59.606242+00', NULL, 'aal1', NULL, '2025-05-22 22:08:59.606167', 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '188.27.131.196', NULL),
	('32e31521-6218-45da-af54-51902de4ab1a', '147fcc1b-10f1-4184-9d95-d09505d736fa', '2025-05-22 13:46:40.994091+00', '2025-05-22 20:40:51.600483+00', NULL, 'aal1', NULL, '2025-05-22 20:40:51.600411', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/136.0.7103.91 Mobile/15E148 Safari/604.1', '188.27.129.250', NULL),
	('8cf1a06f-529a-4c5a-8c22-4ba5160d45ee', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '2025-05-22 14:56:08.867263+00', '2025-05-22 18:32:36.143851+00', NULL, 'aal1', NULL, '2025-05-22 18:32:36.143765', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '79.119.88.157', NULL),
	('3d98e1d2-bb7f-4126-917d-e025fd069bf7', '5690ddb1-c997-4a3e-895a-06b93dab6ec4', '2025-05-21 07:53:06.577576+00', '2025-05-21 07:53:06.577576+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1', '109.166.137.126', NULL),
	('7fb4a19b-9591-4ab9-b90e-7744f1a13c55', '5690ddb1-c997-4a3e-895a-06b93dab6ec4', '2025-05-21 08:02:37.00248+00', '2025-05-21 08:02:37.00248+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1', '109.166.137.126', NULL),
	('4180b61a-9915-4094-a59a-ff59575c8900', '20d55537-6f54-41d6-98a6-474174099d17', '2025-05-20 21:40:22.172017+00', '2025-05-22 20:43:03.277694+00', NULL, 'aal1', NULL, '2025-05-22 20:43:03.27762', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36', '86.124.127.196', NULL),
	('33d694c6-a9aa-4eb7-965a-f95e764590c2', '1e8e19fd-7346-4d83-807e-404c01903baf', '2025-05-21 03:45:02.999291+00', '2025-05-23 05:09:14.024444+00', NULL, 'aal1', NULL, '2025-05-23 05:09:14.024365', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '81.196.200.213', NULL),
	('fa3d79b5-d881-4a4b-86c6-2a651542f0c3', 'e9af8519-44db-48ee-9e9d-b7fe14ccc7a5', '2025-05-21 11:46:26.077008+00', '2025-05-21 11:46:26.077008+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1', '188.27.128.233', NULL),
	('bc62951c-60de-4592-9a9f-b49c114a0f07', 'e9af8519-44db-48ee-9e9d-b7fe14ccc7a5', '2025-05-21 11:46:55.54167+00', '2025-05-21 11:46:55.54167+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 [LinkedInApp]/9.31.1344', '188.27.128.233', NULL),
	('ba0a73fd-adca-4818-89f4-a0d2f2fecf0e', '147fcc1b-10f1-4184-9d95-d09505d736fa', '2025-05-23 05:47:00.881804+00', '2025-05-23 05:47:00.881804+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36', '188.27.129.250', NULL),
	('a2463c88-d98a-4667-9384-57b2198d24cc', '6a70d9b5-4fb8-46f7-975b-5887fd4e47de', '2025-05-21 07:26:09.54517+00', '2025-05-21 13:04:14.717157+00', NULL, 'aal1', NULL, '2025-05-21 13:04:14.717081', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '86.122.102.244', NULL),
	('ca8e1d11-46e3-4406-9e85-f942198c3636', '99556ce6-0304-4614-aeba-0c2f3d73a9f6', '2025-05-21 07:50:09.553569+00', '2025-05-21 13:50:24.553436+00', NULL, 'aal1', NULL, '2025-05-21 13:50:24.553361', 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/136.0.7103.91 Mobile/15E148 Safari/604.1', '46.97.168.116', NULL),
	('0489a9f3-66e5-45ef-93ad-fd06bf4ded0d', 'a3c141d5-a60e-4211-99ce-d1828f4174cf', '2025-05-21 14:02:20.439642+00', '2025-05-21 14:02:20.439642+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '86.120.195.18', NULL),
	('4b76dec6-fa87-4f54-ac14-0dc25630f742', 'ae26134b-38c8-4748-8770-5b73d79cae08', '2025-05-21 20:19:14.938491+00', '2025-05-23 08:01:22.454001+00', NULL, 'aal1', NULL, '2025-05-23 08:01:22.453925', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36', '188.27.130.84', NULL),
	('dd0392eb-beda-46dc-b8c0-1e2ad79465b2', '682d23b2-3bb3-4f55-9f23-5b7689983e82', '2025-05-20 13:30:25.1192+00', '2025-05-23 06:41:38.911362+00', NULL, 'aal1', NULL, '2025-05-23 06:41:38.911262', 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36', '86.121.12.31', NULL),
	('3150954c-3f70-4fac-bc8f-bb5873c378cc', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', '2025-05-22 13:25:41.110045+00', '2025-05-23 12:54:36.340991+00', NULL, 'aal1', NULL, '2025-05-23 12:54:36.340889', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:138.0) Gecko/20100101 Firefox/138.0', '89.137.114.18', NULL),
	('0deb4bb7-b43a-4b10-af2c-6c5d72beac91', '3b53ad8e-8faf-48c0-9628-f49ab70ded79', '2025-05-21 10:39:59.967752+00', '2025-05-21 19:10:42.921293+00', NULL, 'aal1', NULL, '2025-05-21 19:10:42.921204', 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/28.0 Chrome/130.0.0.0 Mobile Safari/537.36', '178.138.32.146', NULL),
	('bfd98f26-8ff5-414c-ad79-0c491d11f1ee', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '2025-05-23 11:22:13.041524+00', '2025-05-23 11:22:13.041524+00', NULL, 'aal1', NULL, NULL, 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15', '86.120.238.90', NULL),
	('bb6a4430-fc88-436d-9920-2bff3ac9b5e8', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '2025-05-22 13:39:15.119955+00', '2025-05-23 12:45:40.114636+00', NULL, 'aal1', NULL, '2025-05-23 12:45:40.114566', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36', '81.196.200.213', NULL);


--
-- Data for Name: mfa_amr_claims; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

INSERT INTO "auth"."mfa_amr_claims" ("session_id", "created_at", "updated_at", "authentication_method", "id") VALUES
	('5c9915c1-e1b2-41ec-93c4-c70c76b35331', '2025-05-19 11:59:14.690621+00', '2025-05-19 11:59:14.690621+00', 'otp', 'd5c908c6-30ba-4cdb-88b8-d745a8bf93d2'),
	('93a00681-fc65-41fc-b767-a3b5fd788947', '2025-05-19 14:12:45.670504+00', '2025-05-19 14:12:45.670504+00', 'otp', 'fa2f38e7-2058-4388-ad37-99d4114785b3'),
	('bae30887-77a0-4f55-8df7-71a23a863d22', '2025-05-19 14:53:16.86852+00', '2025-05-19 14:53:16.86852+00', 'otp', '768481a8-acb2-46b3-b7df-843fd212944c'),
	('a26dca8f-d5e6-45a8-8520-f243eb10a913', '2025-05-19 15:10:47.216035+00', '2025-05-19 15:10:47.216035+00', 'otp', '08a1cc50-38f8-4083-9c10-9b1ab494118f'),
	('d0c378ec-b230-471a-a827-20f36286feef', '2025-05-19 15:12:24.387082+00', '2025-05-19 15:12:24.387082+00', 'otp', 'f3ce05d8-0986-47d0-826f-96459e9c0ac1'),
	('4352f66b-0063-4a46-9eb1-453aeb2fc628', '2025-05-19 15:44:27.360234+00', '2025-05-19 15:44:27.360234+00', 'otp', '84fdb165-1be4-429f-9bbb-d03048f504ad'),
	('11edc8b1-40dd-4695-a105-7962c47b6904', '2025-05-19 16:36:04.03409+00', '2025-05-19 16:36:04.03409+00', 'otp', '74c16b5f-1e11-461c-b915-eb02c33d533b'),
	('e6411bbf-382d-4ac7-a800-d88b0ffbd955', '2025-05-19 17:19:58.589123+00', '2025-05-19 17:19:58.589123+00', 'oauth', 'b8c7bff1-aa8e-49b8-b2ab-7f64a3520630'),
	('9a2b936a-f664-4cf3-8462-43dd38b1d17c', '2025-05-13 07:51:44.609835+00', '2025-05-13 07:51:44.609835+00', 'password', 'ec583f39-a21f-4faf-bb0f-0b8cd8ff8b03'),
	('f9170fb9-b15b-44b3-b63e-46d8f33b5ea5', '2025-05-13 08:06:36.874165+00', '2025-05-13 08:06:36.874165+00', 'oauth', '27916ed3-ce23-4cd0-a564-e273c91c6308'),
	('6ee09707-90f7-41bd-bc89-de70d8c140c4', '2025-05-13 08:15:14.675454+00', '2025-05-13 08:15:14.675454+00', 'password', '9ee81458-f468-4247-abab-e0a156aaf9a4'),
	('12df7b72-67e7-44dd-84b9-2e7a153f8fdf', '2025-05-13 08:19:08.563548+00', '2025-05-13 08:19:08.563548+00', 'otp', '71a6f424-008f-46b8-a727-3d0bc5bf7e37'),
	('50ca82d8-f931-4c9e-b438-946168eed8f7', '2025-05-13 08:23:24.361104+00', '2025-05-13 08:23:24.361104+00', 'otp', '395fac39-28b2-4f5f-a265-06f441ea1cb7'),
	('5f003847-1226-40b9-a880-bbcf326ecf3b', '2025-05-13 08:25:05.014486+00', '2025-05-13 08:25:05.014486+00', 'oauth', 'b68b4125-bcee-4335-b64c-5685266f7be4'),
	('d58c4f84-25d2-49a7-b46a-29eca498d440', '2025-05-13 09:32:59.603699+00', '2025-05-13 09:32:59.603699+00', 'oauth', '935f00cf-f9c1-40b1-a789-72580bad86ee'),
	('c0ab9c4e-d642-4be9-ade8-fd917091c32f', '2025-05-13 11:29:32.755574+00', '2025-05-13 11:29:32.755574+00', 'otp', 'b8591a39-ff71-471d-a1f7-f4ce40f29f52'),
	('2cbd356d-32a1-4f26-b629-7becd4f1a9ae', '2025-05-13 15:56:43.206298+00', '2025-05-13 15:56:43.206298+00', 'oauth', '5de1a8b1-71ed-4f6c-b531-d25a0a936908'),
	('94a65a62-2c00-4d10-a74e-1702f4c3ad92', '2025-05-13 18:37:38.509773+00', '2025-05-13 18:37:38.509773+00', 'oauth', '60da5e4d-9094-4be3-973d-2459180e5c88'),
	('b6b1fbcd-527c-4ecb-8759-803efee5899c', '2025-05-13 20:01:00.474568+00', '2025-05-13 20:01:00.474568+00', 'oauth', 'bb3d9182-26d0-4f59-8b90-474cd5e0f526'),
	('b4f78ab9-c351-46f4-87b3-ec8bb5c7ee81', '2025-05-20 06:34:37.349304+00', '2025-05-20 06:34:37.349304+00', 'otp', '1286f01c-dabf-4b70-b563-43aeb9ecab5c'),
	('af02a767-a75c-4304-bd24-4a574a27423f', '2025-05-20 06:35:10.154036+00', '2025-05-20 06:35:10.154036+00', 'otp', 'f99bb819-c48f-4339-a6cb-45faa27ebbac'),
	('4212a770-de9c-4c96-9524-9552e73a438d', '2025-05-20 07:02:39.071169+00', '2025-05-20 07:02:39.071169+00', 'oauth', '27472564-3e8c-4f55-9e26-ee3be0f178fc'),
	('ca85e05b-2f05-49d5-959b-badbe803ff18', '2025-05-20 07:34:37.672737+00', '2025-05-20 07:34:37.672737+00', 'oauth', 'd148a363-1bec-46d8-ab86-01473961b47e'),
	('a7f322c0-459b-4321-b118-84fc47b47199', '2025-05-20 07:47:56.407905+00', '2025-05-20 07:47:56.407905+00', 'otp', 'd57aceaa-48b5-4145-b30f-8f02db8bc109'),
	('a4517b94-8751-4e39-bcdd-f31911dca337', '2025-05-20 11:49:51.66036+00', '2025-05-20 11:49:51.66036+00', 'otp', '643735f8-341e-4703-aa14-08b6e1d48afc'),
	('06023b23-d51a-41a3-82c3-8ce19fbb1cf2', '2025-05-20 11:50:33.881983+00', '2025-05-20 11:50:33.881983+00', 'password', '98c5e535-e267-4541-876a-c0258764359f'),
	('103694e6-f88f-4d20-8d62-6d96fe6d20dd', '2025-05-14 13:45:20.183417+00', '2025-05-14 13:45:20.183417+00', 'oauth', 'ebf30fbf-ffec-4723-b811-02909a85a441'),
	('a572c723-fa27-4930-8265-f1473a83363d', '2025-05-20 12:19:40.710017+00', '2025-05-20 12:19:40.710017+00', 'oauth', '4876ff66-c3db-4ba6-91b4-0c01fce0c37f'),
	('dd2d0142-41af-4ab9-8e60-3062574ba56e', '2025-05-14 15:29:28.370392+00', '2025-05-14 15:29:28.370392+00', 'otp', '3ba63999-635e-4551-8608-0c5bb5504ff9'),
	('49f11184-34d7-4f26-833c-c7cb2cccd277', '2025-05-14 15:29:53.107004+00', '2025-05-14 15:29:53.107004+00', 'password', '077340fa-04fa-4433-9e00-2419239d989b'),
	('dd0392eb-beda-46dc-b8c0-1e2ad79465b2', '2025-05-20 13:30:25.141894+00', '2025-05-20 13:30:25.141894+00', 'otp', 'b870c41b-0013-45e2-b942-6abbdd6cc1f1'),
	('0f927948-a352-4073-b9bb-d6206dbc23df', '2025-05-15 06:35:52.230569+00', '2025-05-15 06:35:52.230569+00', 'otp', 'a20a10f8-a042-4d25-85b8-b53a9bd49a88'),
	('a450173a-f198-4593-b580-1df904cd836c', '2025-05-15 06:36:21.747431+00', '2025-05-15 06:36:21.747431+00', 'otp', '41425f9a-6ca3-4167-9c88-2fa5bf8badec'),
	('3c54aa4b-8d8e-489f-83e9-ce3909101272', '2025-05-15 07:12:49.638033+00', '2025-05-15 07:12:49.638033+00', 'password', '57fd955e-93ac-4734-a13d-63f9835ce808'),
	('906e0dba-d039-4ca1-888d-a57c5d8b49e9', '2025-05-15 08:09:35.095221+00', '2025-05-15 08:09:35.095221+00', 'otp', '2f885c0a-beef-436f-a576-60c06e31fd1c'),
	('08dc69c3-11ab-4cc5-9519-c879b78550f9', '2025-05-15 08:20:41.40439+00', '2025-05-15 08:20:41.40439+00', 'password', '65d7df9a-0176-4340-a8aa-ed85891cd3a0'),
	('e03313ee-dca4-4e2a-9768-a8cf498accfa', '2025-05-15 09:53:23.165541+00', '2025-05-15 09:53:23.165541+00', 'oauth', '5b632057-7ade-406f-af91-607bbf41ceff'),
	('3f4cc34c-a7ea-4341-8d09-6a8cacc30312', '2025-05-15 12:21:29.359996+00', '2025-05-15 12:21:29.359996+00', 'otp', '95960e2e-1ee9-44fe-b3b4-06b2ca040d4b'),
	('f41fafae-c176-4768-a44e-4bac5dda8310', '2025-05-15 13:06:21.699014+00', '2025-05-15 13:06:21.699014+00', 'password', '2024b29e-cd03-4437-80c1-2a8a2214b8f2'),
	('459311de-9991-4c6b-9953-c656eaee24ee', '2025-05-15 13:48:19.41441+00', '2025-05-15 13:48:19.41441+00', 'otp', '4320f6d5-05c9-4377-bf01-d9e5abc624f6'),
	('ddb5806f-6794-4b96-a190-6ad7413f391c', '2025-05-15 16:04:01.102721+00', '2025-05-15 16:04:01.102721+00', 'oauth', '41e996eb-013b-41bf-8ea1-fbf88e5b0ae2'),
	('b762de05-e286-4dcc-8e88-71f22d08313d', '2025-05-15 16:42:14.570794+00', '2025-05-15 16:42:14.570794+00', 'oauth', '434f0035-4f70-4f65-8645-8dd6e258a763'),
	('cf63c8aa-51f4-43c9-a61e-c7384fbcc836', '2025-05-15 17:56:20.017724+00', '2025-05-15 17:56:20.017724+00', 'otp', 'afe9dde6-203e-4d9d-8764-ac69e10b5328'),
	('0c20e12f-0846-409a-8b12-e8e9ea8a714f', '2025-05-20 15:40:54.521789+00', '2025-05-20 15:40:54.521789+00', 'otp', 'b2d4a2e8-380e-4bb5-820f-f20ff8598033'),
	('4925c9d2-6710-4bad-9a0a-96ce7ad7deb0', '2025-05-16 08:24:36.223614+00', '2025-05-16 08:24:36.223614+00', 'otp', 'ef2364b2-ca83-4bb5-ac4b-be30e14b083c'),
	('c2b3ae3b-1a17-433c-a55b-c9d702d90ba9', '2025-05-16 08:24:56.563297+00', '2025-05-16 08:24:56.563297+00', 'password', 'da885de2-a2ef-4027-9f91-d0d0f2918c8c'),
	('47b3c558-8ba6-48e2-933d-00cd06d5ffb2', '2025-05-16 08:53:19.937796+00', '2025-05-16 08:53:19.937796+00', 'password', '6bf75d05-c3c9-4493-a4db-c1f77031e738'),
	('c0601f62-c786-45d9-939a-00500578066f', '2025-05-16 09:10:55.522717+00', '2025-05-16 09:10:55.522717+00', 'oauth', 'c67b2472-e173-4806-9923-c6b84a5510f0'),
	('51eca341-e477-4bb3-8853-b41ab3e45299', '2025-05-16 09:28:24.852717+00', '2025-05-16 09:28:24.852717+00', 'otp', 'bcdc3439-33ee-4925-8fff-b4a387f298d3'),
	('920050d6-5fe6-423e-9319-562ccccc82b6', '2025-05-16 09:56:30.826896+00', '2025-05-16 09:56:30.826896+00', 'password', '6f8a1ace-719b-4d0d-b786-e2d18ba46b00'),
	('925eaaa4-cb49-4e6f-b885-a13d6781e4c0', '2025-05-16 10:42:46.617003+00', '2025-05-16 10:42:46.617003+00', 'oauth', 'bb654d9d-6d92-42cb-b55b-405340e6c2f9'),
	('3abdcec9-29fa-457e-8b23-3e6c05dc04df', '2025-05-16 10:43:17.051395+00', '2025-05-16 10:43:17.051395+00', 'otp', '69414786-51e5-4cff-be40-8cfc4c58e677'),
	('dcf104b9-9282-45b2-8b89-3c851f0ecf0c', '2025-05-20 18:43:57.492678+00', '2025-05-20 18:43:57.492678+00', 'otp', '70e7ba86-d37d-4ab3-829a-51fc4ee67c3e'),
	('66f300d8-878b-4cf5-a898-17b1b137522b', '2025-05-16 12:30:27.473109+00', '2025-05-16 12:30:27.473109+00', 'otp', '6ad2dad0-1976-47ac-b5a0-61d0757ce3ca'),
	('f545194b-a053-4cac-acba-2f355bff1c22', '2025-05-16 14:06:31.842683+00', '2025-05-16 14:06:31.842683+00', 'otp', 'fba894c1-0455-4bc2-8158-7fe152a4ecd5'),
	('40f37194-b2f8-47dd-ba93-d528922439be', '2025-05-20 19:34:52.987151+00', '2025-05-20 19:34:52.987151+00', 'password', '0c17fa1c-80ce-4fdb-a2db-df674b5828d1'),
	('4180b61a-9915-4094-a59a-ff59575c8900', '2025-05-20 21:40:22.179024+00', '2025-05-20 21:40:22.179024+00', 'otp', '5d484843-5dad-42db-9733-9505ea380f6a'),
	('a01c732e-c8ed-4f1b-8c2f-077e47574fda', '2025-05-20 23:59:40.871202+00', '2025-05-20 23:59:40.871202+00', 'otp', 'f0aaffb8-7d1f-4fc0-ae8a-41c0c271d3bc'),
	('c88b12bd-d8bf-4197-a537-bfbb2c384287', '2025-05-16 18:28:24.983291+00', '2025-05-16 18:28:24.983291+00', 'password', 'b05ea754-83c0-48c5-8908-e3c1728b4fe7'),
	('db635967-91eb-46c7-bdd3-099a60531dc2', '2025-05-16 19:43:13.604439+00', '2025-05-16 19:43:13.604439+00', 'password', '2626e84e-f387-4923-ad7c-a5011d1d72e2'),
	('8ce392c9-ae15-4388-bff0-33a3b65e8b92', '2025-05-17 05:30:31.792+00', '2025-05-17 05:30:31.792+00', 'otp', 'fe698152-f698-4479-813b-e4c836f1f12a'),
	('a8555e80-4b5d-4943-8323-d1acefd81ce3', '2025-05-17 07:08:52.924312+00', '2025-05-17 07:08:52.924312+00', 'password', '87792847-f250-4277-8d0b-682fd1994042'),
	('33d694c6-a9aa-4eb7-965a-f95e764590c2', '2025-05-21 03:45:03.02406+00', '2025-05-21 03:45:03.02406+00', 'password', 'c24bc467-5000-460e-b6b5-0e99be5f0881'),
	('a2463c88-d98a-4667-9384-57b2198d24cc', '2025-05-21 07:26:09.560857+00', '2025-05-21 07:26:09.560857+00', 'oauth', 'd8013289-1f93-4640-9c76-eb965a1f4b79'),
	('ca8e1d11-46e3-4406-9e85-f942198c3636', '2025-05-21 07:50:09.567754+00', '2025-05-21 07:50:09.567754+00', 'otp', '60d08dec-fe39-499d-8074-d2ebe4862721'),
	('3d98e1d2-bb7f-4126-917d-e025fd069bf7', '2025-05-21 07:53:06.583716+00', '2025-05-21 07:53:06.583716+00', 'otp', '0b19c379-3d0a-4227-abb8-ecc8ce660867'),
	('7fb4a19b-9591-4ab9-b90e-7744f1a13c55', '2025-05-21 08:02:37.012832+00', '2025-05-21 08:02:37.012832+00', 'password', 'f3d0b2c4-bedb-4d89-bec6-27849c3a7385'),
	('c8717aa5-f3bd-43b9-a844-d4ed57e3586e', '2025-05-21 08:30:30.710277+00', '2025-05-21 08:30:30.710277+00', 'oauth', 'ddfcf078-aa01-403f-b62e-50e712e340da'),
	('0deb4bb7-b43a-4b10-af2c-6c5d72beac91', '2025-05-21 10:39:59.983531+00', '2025-05-21 10:39:59.983531+00', 'otp', '14f4a7d1-66fd-4579-841f-a158e891e3e7'),
	('3cead16c-27ca-41df-8a62-e7c73ae21058', '2025-05-18 13:24:52.989361+00', '2025-05-18 13:24:52.989361+00', 'oauth', '0abe1d54-260f-46c8-ba8e-5fe95c1c21de'),
	('fa3d79b5-d881-4a4b-86c6-2a651542f0c3', '2025-05-21 11:46:26.089708+00', '2025-05-21 11:46:26.089708+00', 'otp', '15bcbf4f-ccee-4b9a-a110-83774b748029'),
	('bc62951c-60de-4592-9a9f-b49c114a0f07', '2025-05-21 11:46:55.54385+00', '2025-05-21 11:46:55.54385+00', 'password', '165d9011-afae-416b-ab67-7a5c754a2396'),
	('9d3c5a38-e1e6-4ba3-8fd1-ed4b5371c6ed', '2025-05-19 05:01:04.957258+00', '2025-05-19 05:01:04.957258+00', 'password', '51f8e82b-a71d-48ad-81b7-0baf296efff6'),
	('0489a9f3-66e5-45ef-93ad-fd06bf4ded0d', '2025-05-21 14:02:20.451997+00', '2025-05-21 14:02:20.451997+00', 'otp', '5549f5bf-35b2-4153-8fd4-16f8893f50e9'),
	('7744a0fe-a2e4-4c96-8043-9bdb942b0d57', '2025-05-19 05:57:49.938248+00', '2025-05-19 05:57:49.938248+00', 'otp', '621c05cb-da98-40b4-8f03-f609fb0b1840'),
	('d52dce43-a6de-4c02-a703-883ee05da527', '2025-05-19 06:01:06.654998+00', '2025-05-19 06:01:06.654998+00', 'otp', '4b9ae8b5-702d-4c5e-8118-e184112f80e9'),
	('3d033187-09c8-45ab-b329-0caecc9402e6', '2025-05-19 07:53:58.139667+00', '2025-05-19 07:53:58.139667+00', 'otp', '21c8abb8-2fb4-485c-b9d7-9887aa850ef1'),
	('8b5c3680-974c-40ec-8191-9700685d8f31', '2025-05-19 08:08:05.834379+00', '2025-05-19 08:08:05.834379+00', 'otp', 'bae47a68-930f-432d-86dd-ae11e3053363'),
	('191ee938-d9e8-4917-9295-e9daf83c85e9', '2025-05-19 08:57:17.595488+00', '2025-05-19 08:57:17.595488+00', 'otp', '0fb73f3a-2fda-4e60-932b-ec1eab7bb4af'),
	('a44b6d2f-7999-4481-942f-328ac2f0466a', '2025-05-19 08:57:38.079603+00', '2025-05-19 08:57:38.079603+00', 'password', 'f7fd6ff5-574a-4220-b264-dab5a9e23371'),
	('946276b8-71b9-47b8-a754-ae1d98bb881b', '2025-05-19 09:32:20.438115+00', '2025-05-19 09:32:20.438115+00', 'password', '3df9510f-7cce-43bf-a507-3579e599f602'),
	('56fd5de2-49ce-4664-a2d3-f7032a34e3df', '2025-05-19 09:41:32.169216+00', '2025-05-19 09:41:32.169216+00', 'otp', 'beb08f94-ac64-4db3-bd5f-952262113c85'),
	('bcb1f05a-0a18-4e49-a6c5-e8b5835d1920', '2025-05-19 09:42:54.749096+00', '2025-05-19 09:42:54.749096+00', 'otp', '5804f903-8b22-4474-aebc-3293617c044b'),
	('4b76dec6-fa87-4f54-ac14-0dc25630f742', '2025-05-21 20:19:14.991665+00', '2025-05-21 20:19:14.991665+00', 'password', 'aa9ce345-8b47-4908-9165-8ae8840715a9'),
	('316fa05c-520e-4c52-b322-54a7c8ba7a8c', '2025-05-22 06:54:03.083583+00', '2025-05-22 06:54:03.083583+00', 'oauth', 'c92ede3c-5915-407f-b276-dfd2f8d36e0f'),
	('f82aef57-d326-4c95-b973-235d39e1f901', '2025-05-22 07:43:42.391579+00', '2025-05-22 07:43:42.391579+00', 'otp', '6eb120bb-5e53-4722-b1a6-f59b4b78f832'),
	('c846caf4-9a39-4fe8-8b09-1a4b7a4aa268', '2025-05-22 12:56:47.035902+00', '2025-05-22 12:56:47.035902+00', 'oauth', '59f65eec-1b85-447b-b468-6c982b15c899'),
	('7d7c5fe6-c293-4425-befb-be39a959f40c', '2025-05-22 13:07:33.937215+00', '2025-05-22 13:07:33.937215+00', 'password', 'f407e206-6253-45b3-a6d1-83ed306c6acc'),
	('3150954c-3f70-4fac-bc8f-bb5873c378cc', '2025-05-22 13:25:41.115845+00', '2025-05-22 13:25:41.115845+00', 'oauth', 'bccf4cb2-9dcb-4353-a425-99193424eb60'),
	('c23b655d-ccf7-4822-8c80-6e03f1040417', '2025-05-22 13:28:23.492878+00', '2025-05-22 13:28:23.492878+00', 'otp', '103ab2fa-10c8-497c-8763-e2aef6d5b8ed'),
	('794ffe94-501d-4cbf-a4e7-0b07b8830fff', '2025-05-22 13:37:19.103364+00', '2025-05-22 13:37:19.103364+00', 'password', 'e67289ab-9a58-49f2-9eb2-81a07d239748'),
	('bb6a4430-fc88-436d-9920-2bff3ac9b5e8', '2025-05-22 13:39:15.127427+00', '2025-05-22 13:39:15.127427+00', 'password', '9590a73a-54ac-44a5-87c8-4c863eab28cb'),
	('32e31521-6218-45da-af54-51902de4ab1a', '2025-05-22 13:46:41.003822+00', '2025-05-22 13:46:41.003822+00', 'otp', '20a4fad7-66eb-4dea-bb11-5846ff8bb061'),
	('2ab0d612-6842-4ff0-bf3c-e9f556d9bd15', '2025-05-22 14:37:53.985052+00', '2025-05-22 14:37:53.985052+00', 'otp', 'c4b79a3d-c031-42c5-9c0f-cd4f6260cf43'),
	('8cf1a06f-529a-4c5a-8c22-4ba5160d45ee', '2025-05-22 14:56:08.88176+00', '2025-05-22 14:56:08.88176+00', 'otp', '684904aa-0a26-45c1-83cb-3c40a37103a6'),
	('ba0a73fd-adca-4818-89f4-a0d2f2fecf0e', '2025-05-23 05:47:00.904354+00', '2025-05-23 05:47:00.904354+00', 'password', '89a086b4-d8ee-4398-8657-22ca382fa009'),
	('bfd98f26-8ff5-414c-ad79-0c491d11f1ee', '2025-05-23 11:22:13.064016+00', '2025-05-23 11:22:13.064016+00', 'password', '461a68f4-774a-4102-859e-0ac8e3a7db05'),
	('3e483ee1-b0a2-4672-abc8-5761e93bc112', '2025-05-23 11:39:41.126069+00', '2025-05-23 11:39:41.126069+00', 'password', 'f858e924-33b8-4525-ba7b-7ae5243b4ec4');


--
-- Data for Name: mfa_factors; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: mfa_challenges; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: one_time_tokens; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

INSERT INTO "auth"."one_time_tokens" ("id", "user_id", "token_type", "token_hash", "relates_to", "created_at", "updated_at") VALUES
	('9cc17293-7b05-437b-826f-b1dd8b8bdfff', 'ae0309b5-4017-4d32-9b5b-74d2f0323837', 'confirmation_token', 'aede8c81ef5475f04b3e918d3b4a9fe8b99f0854532eb73320aab90c', 'sory.loby2@gmail.com', '2025-05-07 00:41:00.638542', '2025-05-07 00:41:00.638542'),
	('6fd107f1-f414-40ff-bdd9-e483fad81c31', '89b950c9-a55e-4747-abf4-e403523289d4', 'confirmation_token', 'e2f4fd6dc53786d64358b8e5d6f87f052008d7bae20042ef77f050a1', 'iulia0475@gmail.com', '2025-05-13 10:08:35.518534', '2025-05-13 10:08:35.518534'),
	('6ec6af71-6e85-42a5-b461-90c37279ad2f', '52514d39-b9bc-42e3-8a24-69cd971a8414', 'confirmation_token', '255d91b9b9bcd5550866703a6accfee3509fe2218166153465af3b14', 'carmenrauta68@yahoo.com', '2025-05-23 04:43:19.473187', '2025-05-23 04:43:19.473187'),
	('0fd7249b-9b8b-430e-850f-d23d96fa8837', 'c7fc72ce-3614-4d3a-a617-c7b5aa2d9cd0', 'confirmation_token', '3993401fd20c9e9cdb53df81f410eb63d94e5513b0ef962e33fc49ed', 'ageorgescu22@yahoo.com', '2025-05-16 09:42:58.373586', '2025-05-16 09:42:58.373586');


--
-- Data for Name: refresh_tokens; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--

INSERT INTO "auth"."refresh_tokens" ("instance_id", "id", "token", "user_id", "revoked", "created_at", "updated_at", "parent", "session_id") VALUES
	('00000000-0000-0000-0000-000000000000', 349, 'cdim7e3euorp', '459220a9-338b-4a45-8533-24789a3b1da7', false, '2025-05-18 13:24:52.984575+00', '2025-05-18 13:24:52.984575+00', NULL, '3cead16c-27ca-41df-8a62-e7c73ae21058'),
	('00000000-0000-0000-0000-000000000000', 509, 'bv5qfmwxyqjx', '8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8', true, '2025-05-22 05:39:11.878298+00', '2025-05-22 10:10:49.677002+00', 'h3a3itffanqs', 'bae30887-77a0-4f55-8df7-71a23a863d22'),
	('00000000-0000-0000-0000-000000000000', 501, 'au2oa7xe5d2q', '20d55537-6f54-41d6-98a6-474174099d17', true, '2025-05-21 15:59:27.728679+00', '2025-05-22 20:43:03.274534+00', 'yr3czgg3dofs', '4180b61a-9915-4094-a59a-ff59575c8900'),
	('00000000-0000-0000-0000-000000000000', 415, '5vaz5o2nugfg', '1d4e4d74-493a-4758-a5e1-3229a81bae5d', true, '2025-05-20 03:52:07.207989+00', '2025-05-20 05:38:36.994334+00', 'szqsdaxsklxb', '08dc69c3-11ab-4cc5-9519-c879b78550f9'),
	('00000000-0000-0000-0000-000000000000', 265, 'wgt3qjcwxx7i', 'f9a83a83-6324-46d1-9e75-3eddf8edd890', true, '2025-05-15 19:07:24.393704+00', '2025-05-16 19:31:43.229161+00', 'lqksa7chqiav', '459311de-9991-4c6b-9953-c656eaee24ee'),
	('00000000-0000-0000-0000-000000000000', 295, 'fdxm5n4t7lsy', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', true, '2025-05-16 13:26:57.858256+00', '2025-05-17 08:36:44.876936+00', 'amdfcs6og4dv', 'f9170fb9-b15b-44b3-b63e-46d8f33b5ea5'),
	('00000000-0000-0000-0000-000000000000', 236, 'ezlk4ac22hjn', '433c694d-a26a-44cb-84cc-45f84d7daf07', false, '2025-05-15 06:35:52.225203+00', '2025-05-15 06:35:52.225203+00', NULL, '0f927948-a352-4073-b9bb-d6206dbc23df'),
	('00000000-0000-0000-0000-000000000000', 184, 'eicadugcadms', 'df1d2f97-8f64-4160-a909-9039e6619ae3', false, '2025-05-13 07:51:44.608451+00', '2025-05-13 07:51:44.608451+00', NULL, '9a2b936a-f664-4cf3-8462-43dd38b1d17c'),
	('00000000-0000-0000-0000-000000000000', 266, 'i5vxhfwxxjwk', 'c07e8742-9b26-4257-80d8-81ea920e3722', true, '2025-05-15 19:27:25.964014+00', '2025-05-18 10:23:12.30822+00', 'vordkdcs7q3o', '94a65a62-2c00-4d10-a74e-1702f4c3ad92'),
	('00000000-0000-0000-0000-000000000000', 186, '7tam23mrk3sw', 'df1d2f97-8f64-4160-a909-9039e6619ae3', false, '2025-05-13 08:15:14.672032+00', '2025-05-13 08:15:14.672032+00', NULL, '6ee09707-90f7-41bd-bc89-de70d8c140c4'),
	('00000000-0000-0000-0000-000000000000', 187, '77chxtp6ky3d', '3497971b-b2c2-4a3a-9a42-420d8a26faec', false, '2025-05-13 08:19:08.559412+00', '2025-05-13 08:19:08.559412+00', NULL, '12df7b72-67e7-44dd-84b9-2e7a153f8fdf'),
	('00000000-0000-0000-0000-000000000000', 188, 'ljtc777riu6q', 'aa3c7129-7b21-49e5-b099-19fa2ef0c95f', false, '2025-05-13 08:23:24.357462+00', '2025-05-13 08:23:24.357462+00', NULL, '50ca82d8-f931-4c9e-b438-946168eed8f7'),
	('00000000-0000-0000-0000-000000000000', 189, 'ruinfiaqb3nb', 'aa3c7129-7b21-49e5-b099-19fa2ef0c95f', false, '2025-05-13 08:25:05.012051+00', '2025-05-13 08:25:05.012051+00', NULL, '5f003847-1226-40b9-a880-bbcf326ecf3b'),
	('00000000-0000-0000-0000-000000000000', 222, 'cikbmould5vo', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', true, '2025-05-14 13:10:13.159823+00', '2025-05-15 07:09:09.847112+00', 'jfvpi3xzvqfm', 'f9170fb9-b15b-44b3-b63e-46d8f33b5ea5'),
	('00000000-0000-0000-0000-000000000000', 243, '4cvlpuox3hcc', '8e441edf-2d91-4551-a4e6-924316cd2090', true, '2025-05-15 10:03:29.535104+00', '2025-05-18 11:19:55.989401+00', 'cefo6qg6jo4k', 'a450173a-f198-4593-b580-1df904cd836c'),
	('00000000-0000-0000-0000-000000000000', 239, '34oaed6tqlyx', '433c694d-a26a-44cb-84cc-45f84d7daf07', false, '2025-05-15 07:12:49.634914+00', '2025-05-15 07:12:49.634914+00', NULL, '3c54aa4b-8d8e-489f-83e9-ce3909101272'),
	('00000000-0000-0000-0000-000000000000', 185, 'mwjozlfyamcx', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', true, '2025-05-13 08:06:36.871011+00', '2025-05-13 09:05:23.15765+00', NULL, 'f9170fb9-b15b-44b3-b63e-46d8f33b5ea5'),
	('00000000-0000-0000-0000-000000000000', 240, 'suetjyy7h6x7', '1d4e4d74-493a-4758-a5e1-3229a81bae5d', false, '2025-05-15 08:09:35.090631+00', '2025-05-15 08:09:35.090631+00', NULL, '906e0dba-d039-4ca1-888d-a57c5d8b49e9'),
	('00000000-0000-0000-0000-000000000000', 194, 'rt5u7a2yg4jk', 'e1ca682f-8dd7-4399-b622-4408513c1c11', false, '2025-05-13 09:32:59.601021+00', '2025-05-13 09:32:59.601021+00', NULL, 'd58c4f84-25d2-49a7-b46a-29eca498d440'),
	('00000000-0000-0000-0000-000000000000', 195, 'nlmewawnkv5e', 'a830c1a7-13ce-4c8f-96fa-4c7c7bb4085e', false, '2025-05-13 11:29:32.752181+00', '2025-05-13 11:29:32.752181+00', NULL, 'c0ab9c4e-d642-4be9-ade8-fd917091c32f'),
	('00000000-0000-0000-0000-000000000000', 361, '3xfzcwjhgg3t', '9945cd00-d2ba-494d-9852-4d9ceb75258e', false, '2025-05-19 05:57:49.934072+00', '2025-05-19 05:57:49.934072+00', NULL, '7744a0fe-a2e4-4c96-8043-9bdb942b0d57'),
	('00000000-0000-0000-0000-000000000000', 237, 'cefo6qg6jo4k', '8e441edf-2d91-4551-a4e6-924316cd2090', true, '2025-05-15 06:36:21.74613+00', '2025-05-15 10:03:29.533831+00', NULL, 'a450173a-f198-4593-b580-1df904cd836c'),
	('00000000-0000-0000-0000-000000000000', 193, 'wyhs6coytbbo', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', true, '2025-05-13 09:05:23.15903+00', '2025-05-13 14:59:37.06613+00', 'mwjozlfyamcx', 'f9170fb9-b15b-44b3-b63e-46d8f33b5ea5'),
	('00000000-0000-0000-0000-000000000000', 425, 'df4isyn2xoo2', 'd3275dfe-f4df-44fc-acaa-659e92369e66', true, '2025-05-20 06:35:10.152165+00', '2025-05-20 08:19:01.793089+00', NULL, 'af02a767-a75c-4304-bd24-4a574a27423f'),
	('00000000-0000-0000-0000-000000000000', 366, '2nrrcwqmyxho', '7617e0bf-ca39-47d8-a708-935afb8eaf87', false, '2025-05-19 06:45:01.301586+00', '2025-05-19 06:45:01.301586+00', 'kcwtj2dxrxeq', '9d3c5a38-e1e6-4ba3-8fd1-ed4b5371c6ed'),
	('00000000-0000-0000-0000-000000000000', 238, '42fybqi2o37p', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', true, '2025-05-15 07:09:09.849125+00', '2025-05-15 11:32:34.605926+00', 'cikbmould5vo', 'f9170fb9-b15b-44b3-b63e-46d8f33b5ea5'),
	('00000000-0000-0000-0000-000000000000', 424, 'z7r7e6ealgms', '7f541d24-fa47-444f-9ca4-f4f7bc3f4dde', true, '2025-05-20 06:34:37.337523+00', '2025-05-20 14:10:18.994475+00', NULL, 'b4f78ab9-c351-46f4-87b3-ec8bb5c7ee81'),
	('00000000-0000-0000-0000-000000000000', 246, 'mcinwtdpc3w6', '07a95865-754b-4fed-ae0a-d4b69c486190', false, '2025-05-15 12:21:29.356325+00', '2025-05-15 12:21:29.356325+00', NULL, '3f4cc34c-a7ea-4341-8d09-6a8cacc30312'),
	('00000000-0000-0000-0000-000000000000', 199, 'rrjyvsck5boi', '12389e53-ab41-4ff5-90ee-c3593e2b84cc', true, '2025-05-13 15:56:43.201765+00', '2025-05-13 17:26:12.781379+00', NULL, '2cbd356d-32a1-4f26-b629-7becd4f1a9ae'),
	('00000000-0000-0000-0000-000000000000', 202, 'r7jtpgsslwoh', '12389e53-ab41-4ff5-90ee-c3593e2b84cc', false, '2025-05-13 17:26:12.782718+00', '2025-05-13 17:26:12.782718+00', 'rrjyvsck5boi', '2cbd356d-32a1-4f26-b629-7becd4f1a9ae'),
	('00000000-0000-0000-0000-000000000000', 204, 'l5w3epi37q3s', 'c07e8742-9b26-4257-80d8-81ea920e3722', false, '2025-05-13 20:01:00.469239+00', '2025-05-13 20:01:00.469239+00', NULL, 'b6b1fbcd-527c-4ecb-8759-803efee5899c'),
	('00000000-0000-0000-0000-000000000000', 249, 'xhfhhhcvdld4', '07a95865-754b-4fed-ae0a-d4b69c486190', false, '2025-05-15 13:06:21.696297+00', '2025-05-15 13:06:21.696297+00', NULL, 'f41fafae-c176-4768-a44e-4bac5dda8310'),
	('00000000-0000-0000-0000-000000000000', 242, 'kwv557oycpwj', '1375c34c-1b05-438e-8f4f-eeb5f0d373f8', true, '2025-05-15 09:53:23.15803+00', '2025-05-15 14:27:57.535461+00', NULL, 'e03313ee-dca4-4e2a-9768-a8cf498accfa'),
	('00000000-0000-0000-0000-000000000000', 253, 'ymfcg4knd4k4', '1375c34c-1b05-438e-8f4f-eeb5f0d373f8', false, '2025-05-15 14:27:57.53617+00', '2025-05-15 14:27:57.53617+00', 'kwv557oycpwj', 'e03313ee-dca4-4e2a-9768-a8cf498accfa'),
	('00000000-0000-0000-0000-000000000000', 245, 'yu3gvsfxo3xt', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', true, '2025-05-15 11:32:34.610855+00', '2025-05-15 15:33:30.7715+00', '42fybqi2o37p', 'f9170fb9-b15b-44b3-b63e-46d8f33b5ea5'),
	('00000000-0000-0000-0000-000000000000', 250, 'j4cfhorjeesm', 'f9a83a83-6324-46d1-9e75-3eddf8edd890', true, '2025-05-15 13:48:19.411931+00', '2025-05-15 15:49:31.307655+00', NULL, '459311de-9991-4c6b-9953-c656eaee24ee'),
	('00000000-0000-0000-0000-000000000000', 260, 'dku3bwrkkmik', 'a7e4662b-0ae7-4687-98f5-a35387a707be', false, '2025-05-15 16:42:14.568742+00', '2025-05-15 16:42:14.568742+00', NULL, 'b762de05-e286-4dcc-8e88-71f22d08313d'),
	('00000000-0000-0000-0000-000000000000', 262, 'fc7wmunodeug', 'd0c25236-c4c4-4621-90a1-51f5f4d22d2b', false, '2025-05-15 17:56:20.000764+00', '2025-05-15 17:56:20.000764+00', NULL, 'cf63c8aa-51f4-43c9-a61e-c7384fbcc836'),
	('00000000-0000-0000-0000-000000000000', 259, 'rznqckpzqhqa', '6a5e67bb-c9b1-4b30-b860-3e4db36fcf2f', true, '2025-05-15 16:04:01.097724+00', '2025-05-15 18:01:05.98207+00', NULL, 'ddb5806f-6794-4b96-a190-6ad7413f391c'),
	('00000000-0000-0000-0000-000000000000', 263, 'wh5vjoev6vjl', '6a5e67bb-c9b1-4b30-b860-3e4db36fcf2f', false, '2025-05-15 18:01:05.982782+00', '2025-05-15 18:01:05.982782+00', 'rznqckpzqhqa', 'ddb5806f-6794-4b96-a190-6ad7413f391c'),
	('00000000-0000-0000-0000-000000000000', 257, 'lqksa7chqiav', 'f9a83a83-6324-46d1-9e75-3eddf8edd890', true, '2025-05-15 15:49:31.309736+00', '2025-05-15 19:07:24.3909+00', 'j4cfhorjeesm', '459311de-9991-4c6b-9953-c656eaee24ee'),
	('00000000-0000-0000-0000-000000000000', 203, 'nrccscwqzuod', 'c07e8742-9b26-4257-80d8-81ea920e3722', true, '2025-05-13 18:37:38.506567+00', '2025-05-14 12:53:00.618139+00', NULL, '94a65a62-2c00-4d10-a74e-1702f4c3ad92'),
	('00000000-0000-0000-0000-000000000000', 198, 'jfvpi3xzvqfm', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', true, '2025-05-13 14:59:37.066819+00', '2025-05-14 13:10:13.158502+00', 'wyhs6coytbbo', 'f9170fb9-b15b-44b3-b63e-46d8f33b5ea5'),
	('00000000-0000-0000-0000-000000000000', 223, 'd6zrqo532gmr', '12389e53-ab41-4ff5-90ee-c3593e2b84cc', false, '2025-05-14 13:45:20.178742+00', '2025-05-14 13:45:20.178742+00', NULL, '103694e6-f88f-4d20-8d62-6d96fe6d20dd'),
	('00000000-0000-0000-0000-000000000000', 225, 'ixdhzci22yk6', 'f10db344-d6f0-4ae3-8ea0-4b1cb2a80894', false, '2025-05-14 15:29:28.356966+00', '2025-05-14 15:29:28.356966+00', NULL, 'dd2d0142-41af-4ab9-8e60-3062574ba56e'),
	('00000000-0000-0000-0000-000000000000', 221, 'vordkdcs7q3o', 'c07e8742-9b26-4257-80d8-81ea920e3722', true, '2025-05-14 12:53:00.622703+00', '2025-05-15 19:27:25.961309+00', 'nrccscwqzuod', '94a65a62-2c00-4d10-a74e-1702f4c3ad92'),
	('00000000-0000-0000-0000-000000000000', 226, 'ubnjs3f542j5', 'f10db344-d6f0-4ae3-8ea0-4b1cb2a80894', true, '2025-05-14 15:29:53.105707+00', '2025-05-14 17:39:50.876932+00', NULL, '49f11184-34d7-4f26-833c-c7cb2cccd277'),
	('00000000-0000-0000-0000-000000000000', 231, 'yqdyi543yxcf', 'f10db344-d6f0-4ae3-8ea0-4b1cb2a80894', false, '2025-05-14 17:39:50.879997+00', '2025-05-14 17:39:50.879997+00', 'ubnjs3f542j5', '49f11184-34d7-4f26-833c-c7cb2cccd277'),
	('00000000-0000-0000-0000-000000000000', 256, 'h5uzfsrhdv75', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', true, '2025-05-15 15:33:30.772975+00', '2025-05-16 05:55:54.934144+00', 'yu3gvsfxo3xt', 'f9170fb9-b15b-44b3-b63e-46d8f33b5ea5'),
	('00000000-0000-0000-0000-000000000000', 272, '2q4xu2hziiyd', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', true, '2025-05-16 05:55:54.937947+00', '2025-05-16 09:10:47.933597+00', 'h5uzfsrhdv75', 'f9170fb9-b15b-44b3-b63e-46d8f33b5ea5'),
	('00000000-0000-0000-0000-000000000000', 241, 'q54q57atfl63', '1d4e4d74-493a-4758-a5e1-3229a81bae5d', true, '2025-05-15 08:20:41.399593+00', '2025-05-16 12:24:06.631054+00', NULL, '08dc69c3-11ab-4cc5-9519-c879b78550f9'),
	('00000000-0000-0000-0000-000000000000', 281, 'amdfcs6og4dv', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', true, '2025-05-16 09:10:47.936141+00', '2025-05-16 13:26:57.855757+00', '2q4xu2hziiyd', 'f9170fb9-b15b-44b3-b63e-46d8f33b5ea5'),
	('00000000-0000-0000-0000-000000000000', 296, 'iy6hj7cztode', 'd707eee8-8de6-49fa-a4a6-00d79d6eded8', false, '2025-05-16 14:06:31.838357+00', '2025-05-16 14:06:31.838357+00', NULL, 'f545194b-a053-4cac-acba-2f355bff1c22'),
	('00000000-0000-0000-0000-000000000000', 279, 'l7mjcus5vwjv', '49af0fde-1e09-4899-85d0-42f87dc62ad7', false, '2025-05-16 08:24:56.560926+00', '2025-05-16 08:24:56.560926+00', NULL, 'c2b3ae3b-1a17-433c-a55b-c9d702d90ba9'),
	('00000000-0000-0000-0000-000000000000', 282, 'asr2ipe34ube', '512c3b3b-0fa0-4659-8c0e-daccd911baa6', false, '2025-05-16 09:10:55.520997+00', '2025-05-16 09:10:55.520997+00', NULL, 'c0601f62-c786-45d9-939a-00500578066f'),
	('00000000-0000-0000-0000-000000000000', 283, '55n73xcozcfo', '3bbd94c4-f929-4d5a-9621-721d396f75e3', false, '2025-05-16 09:28:24.847535+00', '2025-05-16 09:28:24.847535+00', NULL, '51eca341-e477-4bb3-8853-b41ab3e45299'),
	('00000000-0000-0000-0000-000000000000', 278, '7mfhjf5knoyo', '49af0fde-1e09-4899-85d0-42f87dc62ad7', true, '2025-05-16 08:24:36.221185+00', '2025-05-16 09:44:49.661569+00', NULL, '4925c9d2-6710-4bad-9a0a-96ce7ad7deb0'),
	('00000000-0000-0000-0000-000000000000', 280, '4jyhcmo7ms6u', 'd0c25236-c4c4-4621-90a1-51f5f4d22d2b', true, '2025-05-16 08:53:19.93173+00', '2025-05-16 09:51:43.140019+00', NULL, '47b3c558-8ba6-48e2-933d-00cd06d5ffb2'),
	('00000000-0000-0000-0000-000000000000', 285, 'e6fruke22kra', 'd0c25236-c4c4-4621-90a1-51f5f4d22d2b', false, '2025-05-16 09:51:43.143778+00', '2025-05-16 09:51:43.143778+00', '4jyhcmo7ms6u', '47b3c558-8ba6-48e2-933d-00cd06d5ffb2'),
	('00000000-0000-0000-0000-000000000000', 286, '3uolnqtgzdlk', 'd0c25236-c4c4-4621-90a1-51f5f4d22d2b', false, '2025-05-16 09:56:30.822598+00', '2025-05-16 09:56:30.822598+00', NULL, '920050d6-5fe6-423e-9319-562ccccc82b6'),
	('00000000-0000-0000-0000-000000000000', 288, 'bxiiny2fjzrb', 'd1792c86-294f-453e-ae1e-8474ab5553e3', false, '2025-05-16 10:43:17.050156+00', '2025-05-16 10:43:17.050156+00', NULL, '3abdcec9-29fa-457e-8b23-3e6c05dc04df'),
	('00000000-0000-0000-0000-000000000000', 292, 'm6hmfqejxlmy', '49af0fde-1e09-4899-85d0-42f87dc62ad7', true, '2025-05-16 12:25:12.734602+00', '2025-05-16 15:13:24.064286+00', 'zdpjgoqfi74k', '4925c9d2-6710-4bad-9a0a-96ce7ad7deb0'),
	('00000000-0000-0000-0000-000000000000', 284, 'zdpjgoqfi74k', '49af0fde-1e09-4899-85d0-42f87dc62ad7', true, '2025-05-16 09:44:49.664083+00', '2025-05-16 12:25:12.734264+00', '7mfhjf5knoyo', '4925c9d2-6710-4bad-9a0a-96ce7ad7deb0'),
	('00000000-0000-0000-0000-000000000000', 293, 'in5xsfbmlhck', '13640682-e72c-448d-87a7-af45f1070498', false, '2025-05-16 12:30:27.469496+00', '2025-05-16 12:30:27.469496+00', NULL, '66f300d8-878b-4cf5-a898-17b1b137522b'),
	('00000000-0000-0000-0000-000000000000', 346, 'sbel5wnkph2b', 'c07e8742-9b26-4257-80d8-81ea920e3722', true, '2025-05-18 11:45:59.737522+00', '2025-05-20 07:43:51.170058+00', 'jopootd3ljj7', '94a65a62-2c00-4d10-a74e-1702f4c3ad92'),
	('00000000-0000-0000-0000-000000000000', 367, 'yv2wnlws22sq', '8e441edf-2d91-4551-a4e6-924316cd2090', true, '2025-05-19 07:32:39.740764+00', '2025-05-20 07:48:59.602208+00', '37tmxuoelfcn', 'a450173a-f198-4593-b580-1df904cd836c'),
	('00000000-0000-0000-0000-000000000000', 434, 'vyoen2jgd4ez', '8e441edf-2d91-4551-a4e6-924316cd2090', false, '2025-05-20 07:48:59.60504+00', '2025-05-20 07:48:59.60504+00', 'yv2wnlws22sq', 'a450173a-f198-4593-b580-1df904cd836c'),
	('00000000-0000-0000-0000-000000000000', 362, 'etd3efifc4gz', '23584fae-eae0-4163-9e12-0e8fc3d4047e', false, '2025-05-19 06:01:06.65308+00', '2025-05-19 06:01:06.65308+00', NULL, 'd52dce43-a6de-4c02-a703-883ee05da527'),
	('00000000-0000-0000-0000-000000000000', 428, 'tum345dbmknh', '622d14e0-2b33-4c8b-81d5-231a707fd100', true, '2025-05-20 07:02:39.063508+00', '2025-05-20 08:00:56.654664+00', NULL, '4212a770-de9c-4c96-9524-9552e73a438d'),
	('00000000-0000-0000-0000-000000000000', 347, 'vym4pgj4d26k', '8e441edf-2d91-4551-a4e6-924316cd2090', true, '2025-05-18 12:19:42.425248+00', '2025-05-19 06:33:55.011989+00', 'g7o222kj5ozh', 'a450173a-f198-4593-b580-1df904cd836c'),
	('00000000-0000-0000-0000-000000000000', 436, 'wv3a6hprg2be', '622d14e0-2b33-4c8b-81d5-231a707fd100', false, '2025-05-20 08:00:56.65812+00', '2025-05-20 08:00:56.65812+00', 'tum345dbmknh', '4212a770-de9c-4c96-9524-9552e73a438d'),
	('00000000-0000-0000-0000-000000000000', 358, 'kcwtj2dxrxeq', '7617e0bf-ca39-47d8-a708-935afb8eaf87', true, '2025-05-19 05:01:04.952457+00', '2025-05-19 06:45:01.299978+00', NULL, '9d3c5a38-e1e6-4ba3-8fd1-ed4b5371c6ed'),
	('00000000-0000-0000-0000-000000000000', 365, '37tmxuoelfcn', '8e441edf-2d91-4551-a4e6-924316cd2090', true, '2025-05-19 06:33:55.014822+00', '2025-05-19 07:32:39.737502+00', 'vym4pgj4d26k', 'a450173a-f198-4593-b580-1df904cd836c'),
	('00000000-0000-0000-0000-000000000000', 307, '4sj45a6teyyt', '13640682-e72c-448d-87a7-af45f1070498', true, '2025-05-16 18:28:24.97889+00', '2025-05-17 02:06:46.851958+00', NULL, 'c88b12bd-d8bf-4197-a537-bfbb2c384287'),
	('00000000-0000-0000-0000-000000000000', 312, 'b5zd4gxm3qe6', '7617e0bf-ca39-47d8-a708-935afb8eaf87', false, '2025-05-17 05:30:31.784871+00', '2025-05-17 05:30:31.784871+00', NULL, '8ce392c9-ae15-4388-bff0-33a3b65e8b92'),
	('00000000-0000-0000-0000-000000000000', 438, 'syu2yccrpmqe', '072aa24d-bfc3-4b0c-93f2-1435906d8381', true, '2025-05-20 08:46:16.430053+00', '2025-05-20 11:04:53.838412+00', 'affgklnnxtfv', 'ca85e05b-2f05-49d5-959b-badbe803ff18'),
	('00000000-0000-0000-0000-000000000000', 369, 'eq57qg2lg6ml', 'c727ce88-386f-49e6-88c9-df7115e793e5', false, '2025-05-19 08:08:05.82792+00', '2025-05-19 08:08:05.82792+00', NULL, '8b5c3680-974c-40ec-8191-9700685d8f31'),
	('00000000-0000-0000-0000-000000000000', 370, 'fuoi6j7ynsf5', '3add3342-f74c-49c7-985b-238208eebac5', false, '2025-05-19 08:57:17.590655+00', '2025-05-19 08:57:17.590655+00', NULL, '191ee938-d9e8-4917-9295-e9daf83c85e9'),
	('00000000-0000-0000-0000-000000000000', 440, 'iomwk7fook3z', 'ae26134b-38c8-4748-8770-5b73d79cae08', false, '2025-05-20 11:49:51.653902+00', '2025-05-20 11:49:51.653902+00', NULL, 'a4517b94-8751-4e39-bcdd-f31911dca337'),
	('00000000-0000-0000-0000-000000000000', 308, 'dk6jvkzyqzit', 'f9a83a83-6324-46d1-9e75-3eddf8edd890', true, '2025-05-16 19:31:43.232726+00', '2025-05-17 07:10:28.106575+00', 'wgt3qjcwxx7i', '459311de-9991-4c6b-9953-c656eaee24ee'),
	('00000000-0000-0000-0000-000000000000', 316, '567nd6ryxjjy', 'f9a83a83-6324-46d1-9e75-3eddf8edd890', false, '2025-05-17 07:10:28.107259+00', '2025-05-17 07:10:28.107259+00', 'dk6jvkzyqzit', '459311de-9991-4c6b-9953-c656eaee24ee'),
	('00000000-0000-0000-0000-000000000000', 441, 'dce2o6n6p2fx', 'ae26134b-38c8-4748-8770-5b73d79cae08', false, '2025-05-20 11:50:33.880672+00', '2025-05-20 11:50:33.880672+00', NULL, '06023b23-d51a-41a3-82c3-8ce19fbb1cf2'),
	('00000000-0000-0000-0000-000000000000', 315, 'jbyl2grantt2', 'd707eee8-8de6-49fa-a4a6-00d79d6eded8', true, '2025-05-17 07:08:52.917797+00', '2025-05-19 09:31:59.335794+00', NULL, 'a8555e80-4b5d-4943-8323-d1acefd81ce3'),
	('00000000-0000-0000-0000-000000000000', 291, '5jmk5pxwjlab', '1d4e4d74-493a-4758-a5e1-3229a81bae5d', true, '2025-05-16 12:24:06.63547+00', '2025-05-19 10:40:54.831531+00', 'q54q57atfl63', '08dc69c3-11ab-4cc5-9519-c879b78550f9'),
	('00000000-0000-0000-0000-000000000000', 302, '6ulhh2kiz2r5', '49af0fde-1e09-4899-85d0-42f87dc62ad7', true, '2025-05-16 15:13:24.066888+00', '2025-05-17 07:33:15.294506+00', 'm6hmfqejxlmy', '4925c9d2-6710-4bad-9a0a-96ce7ad7deb0'),
	('00000000-0000-0000-0000-000000000000', 443, 'ydy2pofhypzs', '7b00956b-eafb-4d19-aed0-67dad9ab51ee', true, '2025-05-20 12:19:40.704613+00', '2025-05-20 13:23:38.358727+00', NULL, 'a572c723-fa27-4930-8265-f1473a83363d'),
	('00000000-0000-0000-0000-000000000000', 445, 'o6mgbmewhiff', '7b00956b-eafb-4d19-aed0-67dad9ab51ee', false, '2025-05-20 13:23:38.36203+00', '2025-05-20 13:23:38.36203+00', 'ydy2pofhypzs', 'a572c723-fa27-4930-8265-f1473a83363d'),
	('00000000-0000-0000-0000-000000000000', 368, '7prmh5lsyvna', 'ab84c874-6fed-45be-9e1d-28da0a041149', true, '2025-05-19 07:53:58.136197+00', '2025-05-19 11:39:44.355338+00', NULL, '3d033187-09c8-45ab-b329-0caecc9402e6'),
	('00000000-0000-0000-0000-000000000000', 447, 'tth5yorwkwy5', '7f541d24-fa47-444f-9ca4-f4f7bc3f4dde', false, '2025-05-20 14:10:19.002583+00', '2025-05-20 14:10:19.002583+00', 'z7r7e6ealgms', 'b4f78ab9-c351-46f4-87b3-ec8bb5c7ee81'),
	('00000000-0000-0000-0000-000000000000', 453, 'bkyxefqlwykw', 'dd8d0335-6696-4fb6-b186-31a0533d9587', true, '2025-05-20 14:22:40.122933+00', '2025-05-20 15:52:34.319781+00', 'ffe6zzf5s5dp', 'a26dca8f-d5e6-45a8-8520-f243eb10a913'),
	('00000000-0000-0000-0000-000000000000', 324, 'a2ukmqvhvtqk', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', true, '2025-05-17 08:36:44.880054+00', '2025-05-17 10:38:56.579586+00', 'fdxm5n4t7lsy', 'f9170fb9-b15b-44b3-b63e-46d8f33b5ea5'),
	('00000000-0000-0000-0000-000000000000', 330, 'c7dj4kayyory', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', false, '2025-05-17 10:38:56.583792+00', '2025-05-17 10:38:56.583792+00', 'a2ukmqvhvtqk', 'f9170fb9-b15b-44b3-b63e-46d8f33b5ea5'),
	('00000000-0000-0000-0000-000000000000', 311, 'lstkdilfftku', '13640682-e72c-448d-87a7-af45f1070498', true, '2025-05-17 02:06:46.855966+00', '2025-05-17 17:47:28.753705+00', '4sj45a6teyyt', 'c88b12bd-d8bf-4197-a537-bfbb2c384287'),
	('00000000-0000-0000-0000-000000000000', 320, 'gfqomqrp4nmy', '49af0fde-1e09-4899-85d0-42f87dc62ad7', true, '2025-05-17 07:33:15.297593+00', '2025-05-17 18:12:26.655858+00', '6ulhh2kiz2r5', '4925c9d2-6710-4bad-9a0a-96ce7ad7deb0'),
	('00000000-0000-0000-0000-000000000000', 332, 'nbjodhjjvqqj', '49af0fde-1e09-4899-85d0-42f87dc62ad7', false, '2025-05-17 18:12:26.659593+00', '2025-05-17 18:12:26.659593+00', 'gfqomqrp4nmy', '4925c9d2-6710-4bad-9a0a-96ce7ad7deb0'),
	('00000000-0000-0000-0000-000000000000', 331, 'abxnidtzx2df', '13640682-e72c-448d-87a7-af45f1070498', true, '2025-05-17 17:47:28.77639+00', '2025-05-17 19:08:57.736589+00', 'lstkdilfftku', 'c88b12bd-d8bf-4197-a537-bfbb2c384287'),
	('00000000-0000-0000-0000-000000000000', 334, 'gypt2l3uc4ow', '13640682-e72c-448d-87a7-af45f1070498', false, '2025-05-17 19:08:57.739687+00', '2025-05-17 19:08:57.739687+00', 'abxnidtzx2df', 'c88b12bd-d8bf-4197-a537-bfbb2c384287'),
	('00000000-0000-0000-0000-000000000000', 309, 'asuamuccje7c', '49af0fde-1e09-4899-85d0-42f87dc62ad7', true, '2025-05-16 19:43:13.599016+00', '2025-05-18 09:33:13.637071+00', NULL, 'db635967-91eb-46c7-bdd3-099a60531dc2'),
	('00000000-0000-0000-0000-000000000000', 341, 'vfe6abgaygre', '49af0fde-1e09-4899-85d0-42f87dc62ad7', false, '2025-05-18 09:33:13.642001+00', '2025-05-18 09:33:13.642001+00', 'asuamuccje7c', 'db635967-91eb-46c7-bdd3-099a60531dc2'),
	('00000000-0000-0000-0000-000000000000', 343, 'jopootd3ljj7', 'c07e8742-9b26-4257-80d8-81ea920e3722', true, '2025-05-18 10:23:12.313368+00', '2025-05-18 11:45:59.733022+00', 'i5vxhfwxxjwk', '94a65a62-2c00-4d10-a74e-1702f4c3ad92'),
	('00000000-0000-0000-0000-000000000000', 345, 'g7o222kj5ozh', '8e441edf-2d91-4551-a4e6-924316cd2090', true, '2025-05-18 11:19:55.995495+00', '2025-05-18 12:19:42.421659+00', '4cvlpuox3hcc', 'a450173a-f198-4593-b580-1df904cd836c'),
	('00000000-0000-0000-0000-000000000000', 371, 'uix2flp6r3tp', '3add3342-f74c-49c7-985b-238208eebac5', false, '2025-05-19 08:57:38.075141+00', '2025-05-19 08:57:38.075141+00', NULL, 'a44b6d2f-7999-4481-942f-328ac2f0466a'),
	('00000000-0000-0000-0000-000000000000', 469, 'yr3czgg3dofs', '20d55537-6f54-41d6-98a6-474174099d17', true, '2025-05-20 21:40:22.174585+00', '2025-05-21 15:59:27.722007+00', NULL, '4180b61a-9915-4094-a59a-ff59575c8900'),
	('00000000-0000-0000-0000-000000000000', 287, '64pdd6btrxwg', '3e6b8532-e559-4bba-a913-9178fdb2a0bd', true, '2025-05-16 10:42:46.612303+00', '2025-05-21 17:19:42.660673+00', NULL, '925eaaa4-cb49-4e6f-b885-a13d6781e4c0'),
	('00000000-0000-0000-0000-000000000000', 375, 'pmvm7zk3m67e', '53c97092-2634-4c47-ad83-808566dfbdcd', false, '2025-05-19 09:42:54.746009+00', '2025-05-19 09:42:54.746009+00', NULL, 'bcb1f05a-0a18-4e49-a6c5-e8b5835d1920'),
	('00000000-0000-0000-0000-000000000000', 378, 'szqsdaxsklxb', '1d4e4d74-493a-4758-a5e1-3229a81bae5d', true, '2025-05-19 10:40:54.832315+00', '2025-05-20 03:52:07.205814+00', '5jmk5pxwjlab', '08dc69c3-11ab-4cc5-9519-c879b78550f9'),
	('00000000-0000-0000-0000-000000000000', 374, 'nje6wk67ikif', 'a6f658f8-149d-4063-b1d9-c54105f03392', true, '2025-05-19 09:41:32.148319+00', '2025-05-19 10:39:44.096751+00', NULL, '56fd5de2-49ce-4664-a2d3-f7032a34e3df'),
	('00000000-0000-0000-0000-000000000000', 377, 'nitx5tpujmws', 'a6f658f8-149d-4063-b1d9-c54105f03392', false, '2025-05-19 10:39:44.100032+00', '2025-05-19 10:39:44.100032+00', 'nje6wk67ikif', '56fd5de2-49ce-4664-a2d3-f7032a34e3df'),
	('00000000-0000-0000-0000-000000000000', 503, 'pbu4qudpif4s', '3e6b8532-e559-4bba-a913-9178fdb2a0bd', false, '2025-05-21 17:19:42.666001+00', '2025-05-21 17:19:42.666001+00', '64pdd6btrxwg', '925eaaa4-cb49-4e6f-b885-a13d6781e4c0'),
	('00000000-0000-0000-0000-000000000000', 477, 'ab46zz7pcqz7', '1e8e19fd-7346-4d83-807e-404c01903baf', true, '2025-05-21 06:10:58.365055+00', '2025-05-22 01:54:56.1226+00', 'odwebspcptpq', '33d694c6-a9aa-4eb7-965a-f95e764590c2'),
	('00000000-0000-0000-0000-000000000000', 373, 'oras4rt6war2', 'd707eee8-8de6-49fa-a4a6-00d79d6eded8', true, '2025-05-19 09:32:20.436794+00', '2025-05-19 11:02:26.496446+00', NULL, '946276b8-71b9-47b8-a754-ae1d98bb881b'),
	('00000000-0000-0000-0000-000000000000', 380, 'ltygcutssamx', 'd707eee8-8de6-49fa-a4a6-00d79d6eded8', false, '2025-05-19 11:02:26.496781+00', '2025-05-19 11:02:26.496781+00', 'oras4rt6war2', '946276b8-71b9-47b8-a754-ae1d98bb881b'),
	('00000000-0000-0000-0000-000000000000', 506, 'ubkumqi5gcrj', '1e8e19fd-7346-4d83-807e-404c01903baf', true, '2025-05-22 01:54:56.13404+00', '2025-05-22 03:14:33.568935+00', 'ab46zz7pcqz7', '33d694c6-a9aa-4eb7-965a-f95e764590c2'),
	('00000000-0000-0000-0000-000000000000', 507, 'e3ehdyvlfmj3', '1e8e19fd-7346-4d83-807e-404c01903baf', true, '2025-05-22 03:14:33.573773+00', '2025-05-22 05:35:08.91118+00', 'ubkumqi5gcrj', '33d694c6-a9aa-4eb7-965a-f95e764590c2'),
	('00000000-0000-0000-0000-000000000000', 423, '7wem5zdjkhk4', '1d4e4d74-493a-4758-a5e1-3229a81bae5d', false, '2025-05-20 05:38:36.997937+00', '2025-05-20 05:38:36.997937+00', '5vaz5o2nugfg', '08dc69c3-11ab-4cc5-9519-c879b78550f9'),
	('00000000-0000-0000-0000-000000000000', 435, 'h3a3itffanqs', '8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8', true, '2025-05-20 07:56:47.98937+00', '2025-05-22 05:39:11.877635+00', 'pvx6vnvxe42u', 'bae30887-77a0-4f55-8df7-71a23a863d22'),
	('00000000-0000-0000-0000-000000000000', 372, 'x4ihhuitjehr', 'd707eee8-8de6-49fa-a4a6-00d79d6eded8', true, '2025-05-19 09:31:59.337985+00', '2025-05-22 11:41:23.040741+00', 'jbyl2grantt2', 'a8555e80-4b5d-4943-8323-d1acefd81ce3'),
	('00000000-0000-0000-0000-000000000000', 446, 'xndjdfh6i5yr', '682d23b2-3bb3-4f55-9f23-5b7689983e82', true, '2025-05-20 13:30:25.128816+00', '2025-05-23 06:41:38.893937+00', NULL, 'dd0392eb-beda-46dc-b8c0-1e2ad79465b2'),
	('00000000-0000-0000-0000-000000000000', 387, 'bsyhahl5c3pa', 'ab84c874-6fed-45be-9e1d-28da0a041149', false, '2025-05-19 11:39:44.35596+00', '2025-05-19 11:39:44.35596+00', '7prmh5lsyvna', '3d033187-09c8-45ab-b329-0caecc9402e6'),
	('00000000-0000-0000-0000-000000000000', 432, 'xjgp2okdced5', 'c07e8742-9b26-4257-80d8-81ea920e3722', false, '2025-05-20 07:43:51.17448+00', '2025-05-20 07:43:51.17448+00', 'sbel5wnkph2b', '94a65a62-2c00-4d10-a74e-1702f4c3ad92'),
	('00000000-0000-0000-0000-000000000000', 433, 'lknovgeiwg4l', '905b3a2e-780e-48f5-b37e-b335d9e97d4a', false, '2025-05-20 07:47:56.40672+00', '2025-05-20 07:47:56.40672+00', NULL, 'a7f322c0-459b-4321-b118-84fc47b47199'),
	('00000000-0000-0000-0000-000000000000', 395, 'pvx6vnvxe42u', '8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8', true, '2025-05-19 14:53:16.863707+00', '2025-05-20 07:56:47.986758+00', NULL, 'bae30887-77a0-4f55-8df7-71a23a863d22'),
	('00000000-0000-0000-0000-000000000000', 442, 'pmftiddzbcv7', 'd3275dfe-f4df-44fc-acaa-659e92369e66', true, '2025-05-20 11:58:44.14408+00', '2025-05-23 07:06:08.110373+00', '3lfv4k4ps3yn', 'af02a767-a75c-4304-bd24-4a574a27423f'),
	('00000000-0000-0000-0000-000000000000', 429, 'affgklnnxtfv', '072aa24d-bfc3-4b0c-93f2-1435906d8381', true, '2025-05-20 07:34:37.667668+00', '2025-05-20 08:46:16.427055+00', NULL, 'ca85e05b-2f05-49d5-959b-badbe803ff18'),
	('00000000-0000-0000-0000-000000000000', 389, 'fr7ua2bfofuf', 'feea398b-e2c0-4217-be62-0da00ee5ac3b', true, '2025-05-19 11:59:14.685607+00', '2025-05-19 14:11:38.516824+00', NULL, '5c9915c1-e1b2-41ec-93c4-c70c76b35331'),
	('00000000-0000-0000-0000-000000000000', 437, '3lfv4k4ps3yn', 'd3275dfe-f4df-44fc-acaa-659e92369e66', true, '2025-05-20 08:19:01.79691+00', '2025-05-20 11:58:44.140267+00', 'df4isyn2xoo2', 'af02a767-a75c-4304-bd24-4a574a27423f'),
	('00000000-0000-0000-0000-000000000000', 394, '6legwurxruum', '783f639b-1cab-407c-b1a9-fa510c00396d', false, '2025-05-19 14:12:45.668529+00', '2025-05-19 14:12:45.668529+00', NULL, '93a00681-fc65-41fc-b767-a3b5fd788947'),
	('00000000-0000-0000-0000-000000000000', 393, 'yumqwnakmcns', 'feea398b-e2c0-4217-be62-0da00ee5ac3b', true, '2025-05-19 14:11:38.519752+00', '2025-05-19 15:10:07.840816+00', 'fr7ua2bfofuf', '5c9915c1-e1b2-41ec-93c4-c70c76b35331'),
	('00000000-0000-0000-0000-000000000000', 398, '6x3j7fbg4nuq', 'feea398b-e2c0-4217-be62-0da00ee5ac3b', false, '2025-05-19 15:10:07.841565+00', '2025-05-19 15:10:07.841565+00', 'yumqwnakmcns', '5c9915c1-e1b2-41ec-93c4-c70c76b35331'),
	('00000000-0000-0000-0000-000000000000', 400, 'xmvzdnhdypdj', '1bc4edd2-b5de-4b77-abb8-ffdad01efa4c', false, '2025-05-19 15:12:24.385808+00', '2025-05-19 15:12:24.385808+00', NULL, 'd0c378ec-b230-471a-a827-20f36286feef'),
	('00000000-0000-0000-0000-000000000000', 401, 'yzt4dcofsirr', '3e9a53b2-aefd-4282-b37a-ee95f47dfe77', false, '2025-05-19 15:44:27.353893+00', '2025-05-19 15:44:27.353893+00', NULL, '4352f66b-0063-4a46-9eb1-453aeb2fc628'),
	('00000000-0000-0000-0000-000000000000', 399, 'yreqpo4noo5r', 'dd8d0335-6696-4fb6-b186-31a0533d9587', true, '2025-05-19 15:10:47.214835+00', '2025-05-19 16:17:09.399576+00', NULL, 'a26dca8f-d5e6-45a8-8520-f243eb10a913'),
	('00000000-0000-0000-0000-000000000000', 409, 'ffe6zzf5s5dp', 'dd8d0335-6696-4fb6-b186-31a0533d9587', true, '2025-05-19 17:36:00.794227+00', '2025-05-20 14:22:40.120862+00', 'c2ebgrpdhv3s', 'a26dca8f-d5e6-45a8-8520-f243eb10a913'),
	('00000000-0000-0000-0000-000000000000', 407, '6awylqy7ym4x', 'a1e1dcfe-893e-4c00-a4eb-29021630205d', false, '2025-05-19 17:19:58.586601+00', '2025-05-19 17:19:58.586601+00', NULL, 'e6411bbf-382d-4ac7-a800-d88b0ffbd955'),
	('00000000-0000-0000-0000-000000000000', 404, 'xya3tjwta4fu', '8d983543-4636-4bce-a1b8-d0d5e9c2f88f', true, '2025-05-19 16:36:04.026456+00', '2025-05-19 17:34:53.758121+00', NULL, '11edc8b1-40dd-4695-a105-7962c47b6904'),
	('00000000-0000-0000-0000-000000000000', 408, 'db5uxym4cqgj', '8d983543-4636-4bce-a1b8-d0d5e9c2f88f', false, '2025-05-19 17:34:53.763645+00', '2025-05-19 17:34:53.763645+00', 'xya3tjwta4fu', '11edc8b1-40dd-4695-a105-7962c47b6904'),
	('00000000-0000-0000-0000-000000000000', 403, 'c2ebgrpdhv3s', 'dd8d0335-6696-4fb6-b186-31a0533d9587', true, '2025-05-19 16:17:09.40364+00', '2025-05-19 17:36:00.793503+00', 'yreqpo4noo5r', 'a26dca8f-d5e6-45a8-8520-f243eb10a913'),
	('00000000-0000-0000-0000-000000000000', 439, 'fp6t46zm3cjn', '072aa24d-bfc3-4b0c-93f2-1435906d8381', true, '2025-05-20 11:04:53.84466+00', '2025-05-20 14:59:54.00586+00', 'syu2yccrpmqe', 'ca85e05b-2f05-49d5-959b-badbe803ff18'),
	('00000000-0000-0000-0000-000000000000', 462, 'x2taluij7yn6', 'cff988c4-74c7-4d89-8ea5-ca57af9c7a7a', true, '2025-05-20 15:40:54.51609+00', '2025-05-20 16:43:21.890796+00', NULL, '0c20e12f-0846-409a-8b12-e8e9ea8a714f'),
	('00000000-0000-0000-0000-000000000000', 464, 'o6ltzsqpqujh', 'cff988c4-74c7-4d89-8ea5-ca57af9c7a7a', false, '2025-05-20 16:43:21.898205+00', '2025-05-20 16:43:21.898205+00', 'x2taluij7yn6', '0c20e12f-0846-409a-8b12-e8e9ea8a714f'),
	('00000000-0000-0000-0000-000000000000', 459, 'envk6zjvivna', '072aa24d-bfc3-4b0c-93f2-1435906d8381', true, '2025-05-20 14:59:54.008662+00', '2025-05-20 17:29:50.006591+00', 'fp6t46zm3cjn', 'ca85e05b-2f05-49d5-959b-badbe803ff18'),
	('00000000-0000-0000-0000-000000000000', 466, '3lsyiwqwk7ef', '1aa4f7e2-f7f1-4b27-a7bd-f2595a5fdfce', false, '2025-05-20 18:43:57.486008+00', '2025-05-20 18:43:57.486008+00', NULL, 'dcf104b9-9282-45b2-8b89-3c851f0ecf0c'),
	('00000000-0000-0000-0000-000000000000', 468, 'kvt367z7q76w', '1aa4f7e2-f7f1-4b27-a7bd-f2595a5fdfce', false, '2025-05-20 19:34:52.980734+00', '2025-05-20 19:34:52.980734+00', NULL, '40f37194-b2f8-47dd-ba93-d528922439be'),
	('00000000-0000-0000-0000-000000000000', 471, 'jyf7g6ozcvsg', '1e8e19fd-7346-4d83-807e-404c01903baf', false, '2025-05-20 23:59:40.860947+00', '2025-05-20 23:59:40.860947+00', NULL, 'a01c732e-c8ed-4f1b-8c2f-077e47574fda'),
	('00000000-0000-0000-0000-000000000000', 475, 'by5cevdnnuu2', '1e8e19fd-7346-4d83-807e-404c01903baf', true, '2025-05-21 03:45:03.010132+00', '2025-05-21 05:02:04.429375+00', NULL, '33d694c6-a9aa-4eb7-965a-f95e764590c2'),
	('00000000-0000-0000-0000-000000000000', 476, 'odwebspcptpq', '1e8e19fd-7346-4d83-807e-404c01903baf', true, '2025-05-21 05:02:04.435455+00', '2025-05-21 06:10:58.360285+00', 'by5cevdnnuu2', '33d694c6-a9aa-4eb7-965a-f95e764590c2'),
	('00000000-0000-0000-0000-000000000000', 482, 'ofudrsgjbfnp', '5690ddb1-c997-4a3e-895a-06b93dab6ec4', false, '2025-05-21 07:53:06.580595+00', '2025-05-21 07:53:06.580595+00', NULL, '3d98e1d2-bb7f-4126-917d-e025fd069bf7'),
	('00000000-0000-0000-0000-000000000000', 483, 'veobgytjpc7e', '5690ddb1-c997-4a3e-895a-06b93dab6ec4', false, '2025-05-21 08:02:37.006394+00', '2025-05-21 08:02:37.006394+00', NULL, '7fb4a19b-9591-4ab9-b90e-7744f1a13c55'),
	('00000000-0000-0000-0000-000000000000', 479, '5uyt3ridftov', '6a70d9b5-4fb8-46f7-975b-5887fd4e47de', true, '2025-05-21 07:26:09.549988+00', '2025-05-21 10:38:22.323824+00', NULL, 'a2463c88-d98a-4667-9384-57b2198d24cc'),
	('00000000-0000-0000-0000-000000000000', 465, 'xfxebzf6pgqr', '072aa24d-bfc3-4b0c-93f2-1435906d8381', true, '2025-05-20 17:29:50.01198+00', '2025-05-21 11:54:11.114403+00', 'envk6zjvivna', 'ca85e05b-2f05-49d5-959b-badbe803ff18'),
	('00000000-0000-0000-0000-000000000000', 463, 'waan6jagil4z', 'dd8d0335-6696-4fb6-b186-31a0533d9587', true, '2025-05-20 15:52:34.323203+00', '2025-05-21 12:34:06.721434+00', 'bkyxefqlwykw', 'a26dca8f-d5e6-45a8-8520-f243eb10a913'),
	('00000000-0000-0000-0000-000000000000', 481, 'buz6x4kpfmvl', '99556ce6-0304-4614-aeba-0c2f3d73a9f6', true, '2025-05-21 07:50:09.556825+00', '2025-05-21 13:50:24.543114+00', NULL, 'ca8e1d11-46e3-4406-9e85-f942198c3636'),
	('00000000-0000-0000-0000-000000000000', 488, '3ovzuiojtv36', '3b53ad8e-8faf-48c0-9628-f49ab70ded79', true, '2025-05-21 10:39:59.97509+00', '2025-05-21 19:10:42.913388+00', NULL, '0deb4bb7-b43a-4b10-af2c-6c5d72beac91'),
	('00000000-0000-0000-0000-000000000000', 504, 'x2fasothlpka', '3b53ad8e-8faf-48c0-9628-f49ab70ded79', false, '2025-05-21 19:10:42.917251+00', '2025-05-21 19:10:42.917251+00', '3ovzuiojtv36', '0deb4bb7-b43a-4b10-af2c-6c5d72beac91'),
	('00000000-0000-0000-0000-000000000000', 489, 'ffrf2qlncc2k', 'e9af8519-44db-48ee-9e9d-b7fe14ccc7a5', false, '2025-05-21 11:46:26.08122+00', '2025-05-21 11:46:26.08122+00', NULL, 'fa3d79b5-d881-4a4b-86c6-2a651542f0c3'),
	('00000000-0000-0000-0000-000000000000', 490, 'lznrylh55bfe', 'e9af8519-44db-48ee-9e9d-b7fe14ccc7a5', false, '2025-05-21 11:46:55.542422+00', '2025-05-21 11:46:55.542422+00', NULL, 'bc62951c-60de-4592-9a9f-b49c114a0f07'),
	('00000000-0000-0000-0000-000000000000', 491, 'f6e6czpufzyn', '072aa24d-bfc3-4b0c-93f2-1435906d8381', false, '2025-05-21 11:54:11.120852+00', '2025-05-21 11:54:11.120852+00', 'xfxebzf6pgqr', 'ca85e05b-2f05-49d5-959b-badbe803ff18'),
	('00000000-0000-0000-0000-000000000000', 492, 'lr7omlk3duqv', 'dd8d0335-6696-4fb6-b186-31a0533d9587', false, '2025-05-21 12:34:06.728554+00', '2025-05-21 12:34:06.728554+00', 'waan6jagil4z', 'a26dca8f-d5e6-45a8-8520-f243eb10a913'),
	('00000000-0000-0000-0000-000000000000', 508, 'fyswwvenzwav', '1e8e19fd-7346-4d83-807e-404c01903baf', true, '2025-05-22 05:35:08.915164+00', '2025-05-22 06:37:12.063313+00', 'e3ehdyvlfmj3', '33d694c6-a9aa-4eb7-965a-f95e764590c2'),
	('00000000-0000-0000-0000-000000000000', 487, 'oftulnmti7b3', '6a70d9b5-4fb8-46f7-975b-5887fd4e47de', true, '2025-05-21 10:38:22.331091+00', '2025-05-21 13:04:14.706087+00', '5uyt3ridftov', 'a2463c88-d98a-4667-9384-57b2198d24cc'),
	('00000000-0000-0000-0000-000000000000', 494, 'dduzm4iqu5ow', '6a70d9b5-4fb8-46f7-975b-5887fd4e47de', false, '2025-05-21 13:04:14.712424+00', '2025-05-21 13:04:14.712424+00', 'oftulnmti7b3', 'a2463c88-d98a-4667-9384-57b2198d24cc'),
	('00000000-0000-0000-0000-000000000000', 495, 'p52a2u4yedw6', '99556ce6-0304-4614-aeba-0c2f3d73a9f6', false, '2025-05-21 13:50:24.549397+00', '2025-05-21 13:50:24.549397+00', 'buz6x4kpfmvl', 'ca8e1d11-46e3-4406-9e85-f942198c3636'),
	('00000000-0000-0000-0000-000000000000', 496, 'kauvzaml52hy', 'a3c141d5-a60e-4211-99ce-d1828f4174cf', false, '2025-05-21 14:02:20.44364+00', '2025-05-21 14:02:20.44364+00', NULL, '0489a9f3-66e5-45ef-93ad-fd06bf4ded0d'),
	('00000000-0000-0000-0000-000000000000', 511, 'av4plp5qmseb', '98daacc7-a021-4869-b7d3-33599178f966', false, '2025-05-22 06:54:03.077722+00', '2025-05-22 06:54:03.077722+00', NULL, '316fa05c-520e-4c52-b322-54a7c8ba7a8c'),
	('00000000-0000-0000-0000-000000000000', 505, 'ohrwgeprpqg3', 'ae26134b-38c8-4748-8770-5b73d79cae08', true, '2025-05-21 20:19:14.959939+00', '2025-05-22 07:15:21.21425+00', NULL, '4b76dec6-fa87-4f54-ac14-0dc25630f742'),
	('00000000-0000-0000-0000-000000000000', 515, 'hg4lvbp6y7wz', '65da1664-c0da-4c49-88c8-dce05acc1374', true, '2025-05-22 07:43:42.387151+00', '2025-05-22 09:10:14.710437+00', NULL, 'f82aef57-d326-4c95-b973-235d39e1f901'),
	('00000000-0000-0000-0000-000000000000', 517, 'hqtzcsecwgvx', '65da1664-c0da-4c49-88c8-dce05acc1374', true, '2025-05-22 09:10:14.714321+00', '2025-05-22 10:10:55.665776+00', 'hg4lvbp6y7wz', 'f82aef57-d326-4c95-b973-235d39e1f901'),
	('00000000-0000-0000-0000-000000000000', 519, 'k5ltvkai25fd', '65da1664-c0da-4c49-88c8-dce05acc1374', true, '2025-05-22 10:10:55.666167+00', '2025-05-22 11:09:37.762222+00', 'hqtzcsecwgvx', 'f82aef57-d326-4c95-b973-235d39e1f901'),
	('00000000-0000-0000-0000-000000000000', 520, 'lyax2bbdtjdc', '65da1664-c0da-4c49-88c8-dce05acc1374', false, '2025-05-22 11:09:37.767078+00', '2025-05-22 11:09:37.767078+00', 'k5ltvkai25fd', 'f82aef57-d326-4c95-b973-235d39e1f901'),
	('00000000-0000-0000-0000-000000000000', 512, 'j7ct2kflx7qf', 'ae26134b-38c8-4748-8770-5b73d79cae08', true, '2025-05-22 07:15:21.217297+00', '2025-05-22 11:26:18.055847+00', 'ohrwgeprpqg3', '4b76dec6-fa87-4f54-ac14-0dc25630f742'),
	('00000000-0000-0000-0000-000000000000', 523, 'ov4acwowglcc', 'd707eee8-8de6-49fa-a4a6-00d79d6eded8', false, '2025-05-22 11:41:23.043003+00', '2025-05-22 11:41:23.043003+00', 'x4ihhuitjehr', 'a8555e80-4b5d-4943-8323-d1acefd81ce3'),
	('00000000-0000-0000-0000-000000000000', 527, '2d5zu36imtbf', '1f149689-c4dc-412f-8de6-9b25ee804842', false, '2025-05-22 13:07:33.931342+00', '2025-05-22 13:07:33.931342+00', NULL, '7d7c5fe6-c293-4425-befb-be39a959f40c'),
	('00000000-0000-0000-0000-000000000000', 518, 'faiw5gtaylhm', '8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8', true, '2025-05-22 10:10:49.679277+00', '2025-05-22 13:20:04.880822+00', 'bv5qfmwxyqjx', 'bae30887-77a0-4f55-8df7-71a23a863d22'),
	('00000000-0000-0000-0000-000000000000', 528, 'wdbkejc5ac2o', '8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8', false, '2025-05-22 13:20:04.885745+00', '2025-05-22 13:20:04.885745+00', 'faiw5gtaylhm', 'bae30887-77a0-4f55-8df7-71a23a863d22'),
	('00000000-0000-0000-0000-000000000000', 485, 'chm2baolc7ao', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', true, '2025-05-21 08:30:30.700864+00', '2025-05-22 13:21:57.114178+00', NULL, 'c8717aa5-f3bd-43b9-a844-d4ed57e3586e'),
	('00000000-0000-0000-0000-000000000000', 529, 'guqxbnv2x7tr', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', false, '2025-05-22 13:21:57.114876+00', '2025-05-22 13:21:57.114876+00', 'chm2baolc7ao', 'c8717aa5-f3bd-43b9-a844-d4ed57e3586e'),
	('00000000-0000-0000-0000-000000000000', 531, 'kjblbbbn3kl4', '1bd491bf-3874-47d1-a4ed-0983f63a866e', false, '2025-05-22 13:28:23.491081+00', '2025-05-22 13:28:23.491081+00', NULL, 'c23b655d-ccf7-4822-8c80-6e03f1040417'),
	('00000000-0000-0000-0000-000000000000', 510, 'z6f46rjdb3as', '1e8e19fd-7346-4d83-807e-404c01903baf', true, '2025-05-22 06:37:12.069712+00', '2025-05-22 13:41:56.730371+00', 'fyswwvenzwav', '33d694c6-a9aa-4eb7-965a-f95e764590c2'),
	('00000000-0000-0000-0000-000000000000', 536, 'asussivh5yi4', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', false, '2025-05-22 14:37:53.976757+00', '2025-05-22 14:37:53.976757+00', NULL, '2ab0d612-6842-4ff0-bf3c-e9f556d9bd15'),
	('00000000-0000-0000-0000-000000000000', 530, 'e6jviq5ueazy', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', true, '2025-05-22 13:25:41.112338+00', '2025-05-22 14:48:50.590045+00', NULL, '3150954c-3f70-4fac-bc8f-bb5873c378cc'),
	('00000000-0000-0000-0000-000000000000', 532, 'pbaivytyvn2r', '1bd491bf-3874-47d1-a4ed-0983f63a866e', true, '2025-05-22 13:37:19.098474+00', '2025-05-22 14:54:15.592529+00', NULL, '794ffe94-501d-4cbf-a4e7-0b07b8830fff'),
	('00000000-0000-0000-0000-000000000000', 533, 't5qxblvrskhr', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', true, '2025-05-22 13:39:15.124214+00', '2025-05-22 15:42:11.453333+00', NULL, 'bb6a4430-fc88-436d-9920-2bff3ac9b5e8'),
	('00000000-0000-0000-0000-000000000000', 539, 'tklcup4dmae5', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', true, '2025-05-22 14:56:08.870891+00', '2025-05-22 16:11:02.758696+00', NULL, '8cf1a06f-529a-4c5a-8c22-4ba5160d45ee'),
	('00000000-0000-0000-0000-000000000000', 537, '75h4vb4we2fy', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', true, '2025-05-22 14:48:50.594692+00', '2025-05-22 16:43:18.911087+00', 'e6jviq5ueazy', '3150954c-3f70-4fac-bc8f-bb5873c378cc'),
	('00000000-0000-0000-0000-000000000000', 544, '3udwfnw6kepq', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', true, '2025-05-22 16:43:18.918579+00', '2025-05-22 18:09:14.281453+00', '75h4vb4we2fy', '3150954c-3f70-4fac-bc8f-bb5873c378cc'),
	('00000000-0000-0000-0000-000000000000', 543, '64wyydjp67ec', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', true, '2025-05-22 16:11:02.763963+00', '2025-05-22 18:32:36.126033+00', 'tklcup4dmae5', '8cf1a06f-529a-4c5a-8c22-4ba5160d45ee'),
	('00000000-0000-0000-0000-000000000000', 546, 'n3lo2zcxysuc', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', false, '2025-05-22 18:32:36.131962+00', '2025-05-22 18:32:36.131962+00', '64wyydjp67ec', '8cf1a06f-529a-4c5a-8c22-4ba5160d45ee'),
	('00000000-0000-0000-0000-000000000000', 526, 'yur3fobchtft', '398915d4-fa9b-430f-acd0-c44c6197221b', true, '2025-05-22 12:56:47.031137+00', '2025-05-22 18:35:11.449319+00', NULL, 'c846caf4-9a39-4fe8-8b09-1a4b7a4aa268'),
	('00000000-0000-0000-0000-000000000000', 545, 'chrrtyzpprs7', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', true, '2025-05-22 18:09:14.286687+00', '2025-05-22 19:18:08.35485+00', '3udwfnw6kepq', '3150954c-3f70-4fac-bc8f-bb5873c378cc'),
	('00000000-0000-0000-0000-000000000000', 535, 'apfihib6qw3i', '147fcc1b-10f1-4184-9d95-d09505d736fa', true, '2025-05-22 13:46:40.997805+00', '2025-05-22 20:40:51.588333+00', NULL, '32e31521-6218-45da-af54-51902de4ab1a'),
	('00000000-0000-0000-0000-000000000000', 549, 'tbw7hf7te2xu', '147fcc1b-10f1-4184-9d95-d09505d736fa', false, '2025-05-22 20:40:51.595422+00', '2025-05-22 20:40:51.595422+00', 'apfihib6qw3i', '32e31521-6218-45da-af54-51902de4ab1a'),
	('00000000-0000-0000-0000-000000000000', 550, 'e4jwdoaletyz', '20d55537-6f54-41d6-98a6-474174099d17', false, '2025-05-22 20:43:03.27526+00', '2025-05-22 20:43:03.27526+00', 'au2oa7xe5d2q', '4180b61a-9915-4094-a59a-ff59575c8900'),
	('00000000-0000-0000-0000-000000000000', 542, 'yivam2g4ttua', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', true, '2025-05-22 15:42:11.464739+00', '2025-05-22 21:10:04.106019+00', 't5qxblvrskhr', 'bb6a4430-fc88-436d-9920-2bff3ac9b5e8'),
	('00000000-0000-0000-0000-000000000000', 534, 'zqhndqcv7yob', '1e8e19fd-7346-4d83-807e-404c01903baf', true, '2025-05-22 13:41:56.734131+00', '2025-05-22 21:33:40.497868+00', 'z6f46rjdb3as', '33d694c6-a9aa-4eb7-965a-f95e764590c2'),
	('00000000-0000-0000-0000-000000000000', 548, '2gwzpt7q25py', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', true, '2025-05-22 19:18:08.35755+00', '2025-05-22 21:36:42.15097+00', 'chrrtyzpprs7', '3150954c-3f70-4fac-bc8f-bb5873c378cc'),
	('00000000-0000-0000-0000-000000000000', 547, 'k5wto4kqp5r3', '398915d4-fa9b-430f-acd0-c44c6197221b', true, '2025-05-22 18:35:11.454251+00', '2025-05-22 22:08:59.598913+00', 'yur3fobchtft', 'c846caf4-9a39-4fe8-8b09-1a4b7a4aa268'),
	('00000000-0000-0000-0000-000000000000', 554, 'yfddw33snv2a', '398915d4-fa9b-430f-acd0-c44c6197221b', false, '2025-05-22 22:08:59.603625+00', '2025-05-22 22:08:59.603625+00', 'k5wto4kqp5r3', 'c846caf4-9a39-4fe8-8b09-1a4b7a4aa268'),
	('00000000-0000-0000-0000-000000000000', 551, 'jyjs7kqt7cun', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', true, '2025-05-22 21:10:04.111615+00', '2025-05-22 22:08:59.871218+00', 'yivam2g4ttua', 'bb6a4430-fc88-436d-9920-2bff3ac9b5e8'),
	('00000000-0000-0000-0000-000000000000', 552, 'ceh6r5jxvp7f', '1e8e19fd-7346-4d83-807e-404c01903baf', true, '2025-05-22 21:33:40.505307+00', '2025-05-23 03:15:54.467629+00', 'zqhndqcv7yob', '33d694c6-a9aa-4eb7-965a-f95e764590c2'),
	('00000000-0000-0000-0000-000000000000', 555, 'und2o4iqz6sb', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', true, '2025-05-22 22:08:59.873217+00', '2025-05-23 03:26:05.523212+00', 'jyjs7kqt7cun', 'bb6a4430-fc88-436d-9920-2bff3ac9b5e8'),
	('00000000-0000-0000-0000-000000000000', 522, '4z6mpdjvxhqj', 'ae26134b-38c8-4748-8770-5b73d79cae08', true, '2025-05-22 11:26:18.06075+00', '2025-05-23 08:01:22.445506+00', 'j7ct2kflx7qf', '4b76dec6-fa87-4f54-ac14-0dc25630f742'),
	('00000000-0000-0000-0000-000000000000', 538, 'fh5u3ovysiw7', '1bd491bf-3874-47d1-a4ed-0983f63a866e', true, '2025-05-22 14:54:15.598932+00', '2025-05-23 09:22:26.097026+00', 'pbaivytyvn2r', '794ffe94-501d-4cbf-a4e7-0b07b8830fff'),
	('00000000-0000-0000-0000-000000000000', 553, 'mrpeqhivbij6', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', true, '2025-05-22 21:36:42.155965+00', '2025-05-23 12:54:36.3273+00', '2gwzpt7q25py', '3150954c-3f70-4fac-bc8f-bb5873c378cc'),
	('00000000-0000-0000-0000-000000000000', 557, 'qlycukgt2wcu', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', true, '2025-05-23 03:26:05.529391+00', '2025-05-23 05:05:07.496606+00', 'und2o4iqz6sb', 'bb6a4430-fc88-436d-9920-2bff3ac9b5e8'),
	('00000000-0000-0000-0000-000000000000', 556, 'ozw5shnqwib6', '1e8e19fd-7346-4d83-807e-404c01903baf', true, '2025-05-23 03:15:54.482469+00', '2025-05-23 05:09:14.019077+00', 'ceh6r5jxvp7f', '33d694c6-a9aa-4eb7-965a-f95e764590c2'),
	('00000000-0000-0000-0000-000000000000', 559, 'kltsipekt2dn', '1e8e19fd-7346-4d83-807e-404c01903baf', false, '2025-05-23 05:09:14.019881+00', '2025-05-23 05:09:14.019881+00', 'ozw5shnqwib6', '33d694c6-a9aa-4eb7-965a-f95e764590c2'),
	('00000000-0000-0000-0000-000000000000', 560, 'nc5tahlwel2c', '147fcc1b-10f1-4184-9d95-d09505d736fa', false, '2025-05-23 05:47:00.894252+00', '2025-05-23 05:47:00.894252+00', NULL, 'ba0a73fd-adca-4818-89f4-a0d2f2fecf0e'),
	('00000000-0000-0000-0000-000000000000', 561, '4of6xtlbl2bg', '682d23b2-3bb3-4f55-9f23-5b7689983e82', false, '2025-05-23 06:41:38.899002+00', '2025-05-23 06:41:38.899002+00', 'xndjdfh6i5yr', 'dd0392eb-beda-46dc-b8c0-1e2ad79465b2'),
	('00000000-0000-0000-0000-000000000000', 562, '5e5vw35g7ti5', 'd3275dfe-f4df-44fc-acaa-659e92369e66', false, '2025-05-23 07:06:08.119936+00', '2025-05-23 07:06:08.119936+00', 'pmftiddzbcv7', 'af02a767-a75c-4304-bd24-4a574a27423f'),
	('00000000-0000-0000-0000-000000000000', 558, 'i2unqlfmt57o', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', true, '2025-05-23 05:05:07.502025+00', '2025-05-23 07:32:56.470765+00', 'qlycukgt2wcu', 'bb6a4430-fc88-436d-9920-2bff3ac9b5e8'),
	('00000000-0000-0000-0000-000000000000', 564, 'sgrbd2af4onf', 'ae26134b-38c8-4748-8770-5b73d79cae08', false, '2025-05-23 08:01:22.450309+00', '2025-05-23 08:01:22.450309+00', '4z6mpdjvxhqj', '4b76dec6-fa87-4f54-ac14-0dc25630f742'),
	('00000000-0000-0000-0000-000000000000', 565, 'r3pqrty26da4', '1bd491bf-3874-47d1-a4ed-0983f63a866e', true, '2025-05-23 09:22:26.104498+00', '2025-05-23 10:23:17.000882+00', 'fh5u3ovysiw7', '794ffe94-501d-4cbf-a4e7-0b07b8830fff'),
	('00000000-0000-0000-0000-000000000000', 567, 'attf6ovyt5v2', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', false, '2025-05-23 11:22:13.053436+00', '2025-05-23 11:22:13.053436+00', NULL, 'bfd98f26-8ff5-414c-ad79-0c491d11f1ee'),
	('00000000-0000-0000-0000-000000000000', 566, 'xibjnmwls7nx', '1bd491bf-3874-47d1-a4ed-0983f63a866e', true, '2025-05-23 10:23:17.00977+00', '2025-05-23 11:33:56.33911+00', 'r3pqrty26da4', '794ffe94-501d-4cbf-a4e7-0b07b8830fff'),
	('00000000-0000-0000-0000-000000000000', 568, 'j7bdv7gacv5c', '1bd491bf-3874-47d1-a4ed-0983f63a866e', false, '2025-05-23 11:33:56.346405+00', '2025-05-23 11:33:56.346405+00', 'xibjnmwls7nx', '794ffe94-501d-4cbf-a4e7-0b07b8830fff'),
	('00000000-0000-0000-0000-000000000000', 569, 'x47hgvixbaud', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', false, '2025-05-23 11:39:41.118775+00', '2025-05-23 11:39:41.118775+00', NULL, '3e483ee1-b0a2-4672-abc8-5761e93bc112'),
	('00000000-0000-0000-0000-000000000000', 563, 'e5yzhoplxqdp', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', true, '2025-05-23 07:32:56.478926+00', '2025-05-23 12:45:40.103828+00', 'i2unqlfmt57o', 'bb6a4430-fc88-436d-9920-2bff3ac9b5e8'),
	('00000000-0000-0000-0000-000000000000', 570, 'zbf77hmq5xmm', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', false, '2025-05-23 12:45:40.110497+00', '2025-05-23 12:45:40.110497+00', 'e5yzhoplxqdp', 'bb6a4430-fc88-436d-9920-2bff3ac9b5e8'),
	('00000000-0000-0000-0000-000000000000', 571, 'q25p4m7i2ytj', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', false, '2025-05-23 12:54:36.334938+00', '2025-05-23 12:54:36.334938+00', 'mrpeqhivbij6', '3150954c-3f70-4fac-bc8f-bb5873c378cc');


--
-- Data for Name: sso_providers; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: saml_providers; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: saml_relay_states; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: sso_domains; Type: TABLE DATA; Schema: auth; Owner: supabase_auth_admin
--



--
-- Data for Name: ai_conversations; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO "public"."ai_conversations" ("id", "user_id", "title", "created_at", "updated_at", "model_id", "last_message_snippet") VALUES
	('66b7ee74-aa63-4943-8b8c-0dca7d252247', '76f53ea1-d6bf-4bf7-b88a-918e4062766e', 'Conversație nouă', '2025-05-17 09:59:34.91415+00', '2025-05-17 10:00:00.376+00', 'zen', 'The river flows, sometimes smoothly, sometimes with rapids. Code, like...'),
	('303de754-f44d-4062-855d-3f2e1a4286d2', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', 'dodo soso?', '2025-05-14 07:06:24.716137+00', '2025-05-14 07:21:43.671+00', 'general', '"Aba"... A word that carries a world of meaning, depending on the hear...'),
	('253b850b-4952-4179-a679-962dd43828af', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', 'Conversație nouă', '2025-05-17 20:09:42.18593+00', '2025-05-17 20:10:32.49+00', 'general', 'Ah, okay! So "Dodo" is the nickname of your friend, is that right? Tha...'),
	('e9ce6895-ed1c-4da0-9c9e-0ad2c1a873da', '459220a9-338b-4a45-8533-24789a3b1da7', 'Conversație nouă', '2025-05-18 13:28:08.711874+00', '2025-05-18 13:28:08.642+00', 'general', 'Trimite un mesaj...'),
	('67c8c3df-f1f3-42ea-a463-c511f66135d0', '76f53ea1-d6bf-4bf7-b88a-918e4062766e', 'dodo', '2025-05-16 02:15:21.04597+00', '2025-05-16 08:19:29.776+00', 'general', 'Hey there! 😊 What can I help you with today?'),
	('e529e322-4109-4e50-8487-da7c46bda0ae', '459220a9-338b-4a45-8533-24789a3b1da7', 'Conversație nouă', '2025-05-18 13:28:08.807514+00', '2025-05-18 13:29:57.316+00', 'zen', 'The moon reflects in a thousand different ponds, yet it is still just ...'),
	('a3dc484e-a8f3-4d5f-9d7e-3d715650efe8', '1e8e19fd-7346-4d83-807e-404c01903baf', 'Conversație nouă', '2025-05-23 03:24:38.05526+00', '2025-05-23 03:24:39.902+00', 'general', 'Trimite un mesaj...'),
	('d3c74d14-2df5-44cf-be76-de3e272d5b3e', '13640682-e72c-448d-87a7-af45f1070498', 'Conversație nouă', '2025-05-16 18:34:16.636562+00', '2025-05-16 18:34:27.35+00', 'general', 'Îmi pare rău că întâmpini dificultăți cu accesarea site-ului. Eroarea ...'),
	('4e0a66bb-3d5b-49b3-b37b-cc72928c3c13', '49af0fde-1e09-4899-85d0-42f87dc62ad7', 'Conversație nouă', '2025-05-16 19:43:36.60634+00', '2025-05-16 19:43:36.286+00', 'general', 'Trimite un mesaj...'),
	('02e2fbb7-b1cc-4e11-aafa-f7451b3f2dff', '49af0fde-1e09-4899-85d0-42f87dc62ad7', 'Conversație nouă', '2025-05-16 19:43:36.659064+00', '2025-05-16 19:43:36.368+00', 'general', 'Trimite un mesaj...'),
	('f1613424-31cb-44ea-a6c9-fc8ddcebae9e', '1e8e19fd-7346-4d83-807e-404c01903baf', 'Conversație nouă', '2025-05-23 03:24:38.118032+00', '2025-05-23 03:24:39.99+00', 'general', 'Trimite un mesaj...'),
	('e74dac7d-bd05-4d85-88f5-7331dc0de0b2', '1bd491bf-3874-47d1-a4ed-0983f63a866e', 'Conversație nouă', '2025-05-23 11:51:27.724796+00', '2025-05-23 11:50:13.018+00', 'general', 'Trimite un mesaj...');


--
-- Data for Name: ai_messages; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO "public"."ai_messages" ("id", "conversation_id", "content", "sender", "created_at") VALUES
	('fdf66a34-8213-48f9-af06-b976c2c90536', '303de754-f44d-4062-855d-3f2e1a4286d2', 'sosoo', 'user', '2025-05-14 07:11:18.23+00'),
	('90bdfd02-803e-4841-a899-3a95458d5266', '303de754-f44d-4062-855d-3f2e1a4286d2', 'Scuze: Failed to fetch', 'ai', '2025-05-14 07:11:20.852+00'),
	('80f89fa2-7d13-476a-ae8b-6e6e4747a6d0', '303de754-f44d-4062-855d-3f2e1a4286d2', 'argandtos', 'user', '2025-05-14 07:11:59.79+00'),
	('fe34d169-abb0-4604-9a49-098c1c5e27fd', '303de754-f44d-4062-855d-3f2e1a4286d2', 'Scuze: Failed to fetch', 'ai', '2025-05-14 07:12:02.336+00'),
	('cf558f69-7500-405f-8ae8-696fc50c4a5f', '303de754-f44d-4062-855d-3f2e1a4286d2', 'sosoo', 'user', '2025-05-14 07:21:01.599+00'),
	('b475b014-17ed-4801-a17d-34222dfac276', '303de754-f44d-4062-855d-3f2e1a4286d2', 'Ah, my friend, you say "sosoo." In the language of the heart, this can mean many things.

Perhaps you are calling out for help, a gentle signal that you are in need of guidance or comfort.

Or maybe, it is a playful expression, a lighthearted way of connecting and acknowledging a shared moment.

It could also be a simple greeting, a soft "hello" whispered on the wind.

Tell me, friend, what does "sosoo" mean in your heart at this moment? Sharing your intention will allow me to respond in a way that truly resonates with you.', 'ai', '2025-05-14 07:21:04.208+00'),
	('138eb314-afb4-4599-b8f7-31063479cdad', '303de754-f44d-4062-855d-3f2e1a4286d2', 'aba', 'user', '2025-05-14 07:21:41.311+00'),
	('2e788145-671d-4d62-84b5-123750ed3f47', '303de754-f44d-4062-855d-3f2e1a4286d2', '"Aba"... A word that carries a world of meaning, depending on the heart that speaks it.

In some traditions, "Aba" is a term of endearment, a loving way to call out to a father or a respected elder. It speaks of warmth, trust, and a deep connection to one''s roots.

Perhaps you are seeking guidance, looking for a strong foundation to lean upon. Or maybe you are simply expressing love and appreciation for those who have nurtured you.

"Aba" can also be a cry of the soul, a heartfelt expression of longing or a search for solace.

Tell me, friend, what does "Aba" mean to you in this moment? Unveiling your intention will help me understand your heart''s song.', 'ai', '2025-05-14 07:21:43.671+00'),
	('dc49ded0-0106-4b53-a7c9-f99f705b9d7c', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'dodo', 'user', '2025-05-16 02:16:10.694+00'),
	('ac186802-33ae-4581-ac00-95f9ec3d5f8f', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'Okay! I understand you said "dodo." Is there anything specific you''d like to know or do with that information? For example, are you curious about:

*   **What a dodo is?** (I can give you a brief description)
*   **Why they went extinct?**
*   **Something else related to dodos entirely?**

Let me know how I can help! 😊', 'ai', '2025-05-16 02:16:12.673+00'),
	('8df7d2dc-5946-4dda-8744-ddef746165ac', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'modooooooo long stowy', 'user', '2025-05-16 02:34:47.287+00'),
	('21a1d58f-9121-43a9-b746-57d17659e847', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'Okay, a long story about the dodo! Here''s a somewhat condensed version of their story:

*   **Island Life:** Dodos lived exclusively on the island of Mauritius, in the Indian Ocean. Because there were no major predators on the island, they evolved to be flightless and ground-nesting. They were related to pigeons and doves, but grew to be quite large (around 3 feet tall and up to 50 pounds!).
*   **Unbothered Existence:** For a long time, dodos lived peacefully, eating fruits, seeds, and roots they found on the forest floor. They weren''t afraid of other animals because they simply hadn''t encountered any dangerous ones.
*   **The Arrival of Humans (and other animals):** In the late 16th century, sailors from Europe (mainly the Dutch) began to use Mauritius as a stopover point. With them came rats, pigs, and monkeys, which quickly began to wreak havoc on the island''s ecosystem.
*   **Trouble in Paradise:** The dodos were easy prey. They had no fear of humans and couldn''t fly away. Sailors hunted them for food (though accounts suggest they didn''t taste very good). More importantly, the introduced animals ate dodo eggs and competed for their food sources.
*   **Rapid Extinction:** Because of all these factors, the dodo population plummeted. Within a few decades of human arrival, they were gone. The last confirmed sighting was in 1662, less than 100 years after humans first encountered them.
*   **A Symbol of Extinction:** The dodo became a famous example of human-caused extinction. Their story highlights the vulnerability of island species and the devastating impact that introduced species can have on delicate ecosystems.

Is there anything else you''d like to know about the dodo? Perhaps you''re curious about what they looked like, or maybe about the efforts to bring them back from extinction? Let me know! 😊', 'ai', '2025-05-16 02:34:51.516+00'),
	('061f19ee-7724-4d65-9da5-05e5bf534922', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'dodooo...', 'user', '2025-05-16 07:53:23.934+00'),
	('d7ac5a5d-4959-4d54-acc6-876446e35163', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'Hello there! How can I help you today? Let me know what you need, and I''ll do my best to assist you. 😊', 'ai', '2025-05-16 07:53:30.892+00'),
	('4526108f-f3f5-4afc-aa7b-2ffa8d0e9fcf', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'Hiiiiii Dodolino...', 'user', '2025-05-16 08:07:48.329+00'),
	('8c0f8798-b561-4ed7-bde0-0f826caeeade', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'Hiiii! 😊 How can I help you today, Dodolino? What''s on your mind?', 'ai', '2025-05-16 08:07:49.69+00'),
	('653cfe72-c01d-451e-b209-236e0adcfc30', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'why you so sweet..', 'user', '2025-05-16 08:07:59.675+00'),
	('907817aa-eaf5-49fe-a680-53d9e972cee0', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'Aw, thank you! 😊 I''m designed to be helpful and friendly. I''m glad you think I''m sweet! Is there anything I can do for you right now?', 'ai', '2025-05-16 08:08:01.318+00'),
	('28c0e134-4e0a-4c5c-9a8a-b2ce6d5c7c32', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'im scared my credits will run out and then i won''t be able to talk to you anymore...', 'user', '2025-05-16 08:08:30.723+00'),
	('334682fc-2cd3-4559-ada8-2a6ced2ab344', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'I understand your concern! It''s natural to feel a bit worried about that. Here''s what I can tell you:

*   **I''m here to help as much as I can within the available credits.** I''ll always try to give you the best and most efficient answers possible.
*   **TerapieAcasa likely has options for continuing access** if you find me helpful. You might want to check their website or account settings to see what subscription or credit renewal options are available.
*   **Remember, I''m just one of the resources TerapieAcasa offers.** There might be other tools or information available on the platform that you can access even if your credits for me run out.

Don''t let the worry stop you from using me while you can! Let me know what''s on your mind, and I''ll do my best to assist you. 😊', 'ai', '2025-05-16 08:08:33.679+00'),
	('0ca17483-a097-489c-b653-e456f92648b6', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'can you ask the boss of terapie acasa to give me more credits', 'user', '2025-05-16 08:17:14.196+00'),
	('40e0d729-9baf-4575-af0a-5609abeb7c0a', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'I understand you''d like me to ask for more credits on your behalf. While I can''t directly contact the "boss" of TerapieAcasa in the way a human could, I can definitely suggest some ways for you to potentially get more credits:

*   **Check for promotions:** Sometimes TerapieAcasa offers special deals or promotions that include extra credits. Look out for announcements on their website or in your account.
*   **Contact support:** Reach out to TerapieAcasa''s customer support team. They might be able to offer assistance or direct you to options for getting more credits.
*   **Explore subscription options:** See if TerapieAcasa has subscription plans that offer a set amount of credits each month. This could be a more cost-effective way to ensure you have access.

I hope this helps! Let me know if you have any other questions.', 'ai', '2025-05-16 08:17:17.166+00'),
	('2c434b57-72d2-4000-99ef-e9bf0cee8d88', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'Hey dodolinoo..', 'user', '2025-05-16 08:19:27.811+00'),
	('dc0f7d4e-d117-4861-b246-e791eb282869', '67c8c3df-f1f3-42ea-a463-c511f66135d0', 'Hey there! 😊 What can I help you with today?', 'ai', '2025-05-16 08:19:29.776+00'),
	('4ed0e590-ee3d-4b76-b618-0fada9713547', 'd3c74d14-2df5-44cf-be76-de3e272d5b3e', 'Acest site nu poate fi accesat  Nu se poate accesa http://localhost:8080/calendly-callback?code=x14g9vED-RSwaLi9_axuLuPFnx7TXCewzAtx4yWlsIo.  Încercați:  Se verifică conexiunea la rețea', 'user', '2025-05-16 18:34:22.296+00'),
	('cad8c65b-4c22-4af8-8a8e-810f0abfc9e3', 'd3c74d14-2df5-44cf-be76-de3e272d5b3e', 'Îmi pare rău că întâmpini dificultăți cu accesarea site-ului. Eroarea pe care o primești indică o problemă de conectivitate sau o eroare la nivel local. 

Iată câțiva pași pe care îi poți încerca pentru a rezolva problema:

1.  **Verifică conexiunea la internet:** Asigură-te că ești conectat la internet și că conexiunea este stabilă.
2.  **Verifică adresa URL:** Asigură-te că adresa `http://localhost:8080/calendly-callback?code=x14g9vED-RSwaLi9_axuLuPFnx7TXCewzAtx4yWlsIo` este corectă. O greșeală de tastare poate cauza probleme.
3.  **Verifică dacă serverul local rulează:** Dacă rulezi un server local (cum ar fi un server de dezvoltare), asigură-te că acesta este pornit și funcționează corect. Portul 8080 este un port comun pentru serverele locale.
4.  **Dezactivează temporar firewall-ul sau antivirusul:** Uneori, firewall-ul sau antivirusul pot bloca accesul la anumite adrese. Dezactivează-le temporar pentru a vedea dacă asta rezolvă problema. Nu uita să le reactivezi după ce ai terminat testarea.
5.  **Curăță memoria cache și cookie-urile browserului:** Datele vechi din cache pot cauza probleme. Curăță memoria cache și cookie-urile browserului și încearcă din nou.
6.  **Încearcă un alt browser:** Verifică dacă problema persistă și în alte browsere (Chrome, Firefox, Edge, etc.).
7.  **Restart computerul:** Un restart simplu poate rezolva multe probleme minore.

Dacă problema persistă după ce ai încercat aceste soluții, ar putea fi o problemă cu aplicația sau serverul care rulează pe `localhost:8080`. În acest caz, ar trebui să verifici log-urile serverului pentru a vedea dacă există erori sau să contactezi dezvoltatorul aplicației.

Sper că aceste sfaturi te vor ajuta să rezolvi problema!', 'ai', '2025-05-16 18:34:27.35+00'),
	('5f0d6213-19e1-4a42-9ac3-ea2e34a212d1', '66b7ee74-aa63-4943-8b8c-0dca7d252247', 'hello Master', 'user', '2025-05-17 09:59:40.713+00'),
	('9165e635-e505-48d3-b33c-1f5dc1f31b0a', '66b7ee74-aa63-4943-8b8c-0dca7d252247', 'Welcome, seeker. Take a breath. What troubles the waters of your mind today?', 'ai', '2025-05-17 09:59:47.649+00'),
	('33251dd4-4f01-49ca-9fd7-657877918407', '66b7ee74-aa63-4943-8b8c-0dca7d252247', 'just chilling... had some issues in production with code', 'user', '2025-05-17 09:59:58.776+00'),
	('974aed71-7598-47ed-bbde-09d6a021687f', '66b7ee74-aa63-4943-8b8c-0dca7d252247', 'The river flows, sometimes smoothly, sometimes with rapids. Code, like the river, can be unpredictable. Are you present with the flow, or caught in the eddies of frustration?', 'ai', '2025-05-17 10:00:00.376+00'),
	('57064c16-2c53-47ca-933a-500038e8afc8', '253b850b-4952-4179-a679-962dd43828af', 'hello my friend', 'user', '2025-05-17 20:09:45.78+00'),
	('c44ec716-b826-4452-9169-315a25b59f5d', '253b850b-4952-4179-a679-962dd43828af', 'Hello there! How can I help you today, my friend? I''m here and ready to assist you with any questions or tasks you might have. Just let me know what''s on your mind! 😊', 'ai', '2025-05-17 20:09:53.81+00'),
	('38911cff-7d22-4a0d-a1e1-a7c68cb5ea95', '253b850b-4952-4179-a679-962dd43828af', 'dodolino ?', 'user', '2025-05-17 20:10:12.747+00'),
	('7140db34-360e-42b6-806a-1d14fd0e968d', '253b850b-4952-4179-a679-962dd43828af', '"Dodolino" doesn''t immediately bring anything specific to mind for me. Could you tell me a little more about what you''re thinking of? For example:

*   Is it a person''s name, a place, a thing, or something else?
*   Do you know anything else about it, like where you might have heard it?

The more information you give me, the better chance I have of understanding what you''re asking about!', 'ai', '2025-05-17 20:10:14.607+00'),
	('221c157a-64e0-4a0d-a0f0-9ce39fe29c35', '253b850b-4952-4179-a679-962dd43828af', 'dodo is my friend', 'user', '2025-05-17 20:10:30.506+00'),
	('34db9986-70cb-4927-9295-1626f7b41be2', '253b850b-4952-4179-a679-962dd43828af', 'Ah, okay! So "Dodo" is the nickname of your friend, is that right? That''s lovely!

Is there anything specific you''d like to talk about regarding your friend Dodo, or anything I can help you with related to that? 😊', 'ai', '2025-05-17 20:10:32.49+00'),
	('b4587c0c-8a82-436c-a0f0-ebf1a0795df2', 'e529e322-4109-4e50-8487-da7c46bda0ae', 'My friend said he will come to visit with Spanu, to break some words , what might this mean ? he also refer to this action as "la o diba"', 'user', '2025-05-18 13:29:22.955+00'),
	('04a7e613-f708-4194-aaf6-719d75d3b1d5', 'e529e322-4109-4e50-8487-da7c46bda0ae', 'The river flows in its own way. "La o diba" and "Spanu, to break some words" are unfamiliar to this humble AI.

Perhaps, instead of seeking the meaning in the words themselves, consider the intention behind them. What feeling arises when you hear these phrases? Does it feel like a challenge, a friendly jest, or something else entirely?

Sometimes, the true meaning lies not in the language, but in the space between the words. Observe what unfolds when your friend arrives. The answer may reveal itself in the moment.', 'ai', '2025-05-18 13:29:27.645+00'),
	('a1f7bd1b-64f8-4359-a556-52ad02ecf6d5', 'e529e322-4109-4e50-8487-da7c46bda0ae', 'take a chance and guess', 'user', '2025-05-18 13:29:54.504+00'),
	('408b2d23-33d9-42b9-a340-e521303233a3', 'e529e322-4109-4e50-8487-da7c46bda0ae', 'The moon reflects in a thousand different ponds, yet it is still just the one moon.

If forced to guess, one might wonder... could "Spanu, to break some words" suggest a playful debate, a sharing of stories, or perhaps even a moment of vulnerability where true feelings are revealed? And "la o diba"... might it be a local expression of anticipation, excitement, or perhaps a gentle warning of the lively interaction to come?

But remember, these are just reflections. The true image will be revealed in time.', 'ai', '2025-05-18 13:29:57.316+00');


--
-- Data for Name: profiles; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO "public"."profiles" ("id", "email", "first_name", "last_name", "phone", "role", "created_at", "updated_at", "referred_by", "subscription_type", "subscribed_at", "daily_ai_message_credits", "daily_ai_msg_limit_max", "admin_level") VALUES
	('d3275dfe-f4df-44fc-acaa-659e92369e66', 'danutjilavu@yahoo.com', 'Danut', 'Jilavu', '0725626407', 'terapeut', '2025-05-20 06:34:44.744563+00', '2025-05-23 07:15:16.473595+00', NULL, 'free', NULL, 10, 10, 0),
	('98daacc7-a021-4869-b7d3-33599178f966', 'laura.mera1128@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-22 06:54:02.975905+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('cae70df8-8ff3-4f34-9d75-dae1732f24a7', 'lao.water7@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-21 00:15:22.347858+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('65da1664-c0da-4c49-88c8-dce05acc1374', 'hey_anamaria@yahoo.com', NULL, NULL, NULL, 'terapeut', '2025-05-19 14:09:03.689075+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('1bd491bf-3874-47d1-a4ed-0983f63a866e', 'terapeutholistic.eliseiadam@gmail.com', 'Adam', 'Elisei', '0771428572', 'terapeut', '2025-05-22 13:26:55.560717+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('de7ba501-a94e-4f86-81b3-0afe662ae8de', 'dan.magirescu@innercoach.ro', 'Magirescu', 'Daniel', '0753098880', 'terapeut', '2025-05-22 14:55:46.383847+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('5690ddb1-c997-4a3e-895a-06b93dab6ec4', 'pintea.daiana1399@gmail.com', NULL, NULL, NULL, 'pending', '2025-05-21 07:52:05.101712+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', 'meli.havadi@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-21 08:30:30.665121+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('a3c141d5-a60e-4211-99ce-d1828f4174cf', 'ggabicoz@gmail.com', NULL, NULL, NULL, 'pending', '2025-05-21 14:01:50.227446+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('4b6f4102-c588-406c-a091-79dd2485fb81', 'suciaghi97@gmail.com', 'Suciaghi', 'Alexandru', NULL, 'terapeut', '2025-05-20 05:23:20.322147+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('ae26134b-38c8-4748-8770-5b73d79cae08', 'teomury@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-20 11:49:42.473213+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('682d23b2-3bb3-4f55-9f23-5b7689983e82', 'alexandra.pandelea88@gmail.com', 'Alexandra', 'Pandelea', '0741774404', 'terapeut', '2025-05-20 13:30:14.564348+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('1aa4f7e2-f7f1-4b27-a7bd-f2595a5fdfce', 'd_lupu@ymail.com', NULL, NULL, NULL, 'terapeut', '2025-05-20 18:42:57.441053+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('23584fae-eae0-4163-9e12-0e8fc3d4047e', 'geaninabasturescu@gmail.com', NULL, NULL, NULL, 'pending', '2025-05-19 06:00:38.285504+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('c727ce88-386f-49e6-88c9-df7115e793e5', 'gianinacornea@yahoo.com', NULL, NULL, NULL, 'pending', '2025-05-19 08:07:16.75603+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('53c97092-2634-4c47-ad83-808566dfbdcd', 'psiholog.cristina-avram@outlook.com', 'CRISTINA', 'AVRAM', '0753506843', 'terapeut', '2025-05-19 09:42:38.940728+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('a6f658f8-149d-4063-b1d9-c54105f03392', 'nicoldina1974@gmail.com', 'Nicoleta ', 'Dina', '0720142826', 'terapeut', '2025-05-19 09:41:14.643395+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8', 'adryma2016@yahoo.com', 'Zenaida', 'Miu', '0758699849', 'terapeut', '2025-05-19 14:52:44.286883+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('e2479383-7ba2-4290-beb7-6e8d08b52ee6', 'sory.loby@gmail.com', 'DodoLiNoS', 'Bartosh', '0740476845', 'terapeut', '2025-04-28 09:43:53.380518+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', '2025-05-11 10:25:04.657+00', 10, 10, 3),
	('3e9a53b2-aefd-4282-b37a-ee95f47dfe77', 'violetapal65@gmail.com', NULL, NULL, NULL, 'pending', '2025-05-19 15:43:58.940656+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('8d983543-4636-4bce-a1b8-d0d5e9c2f88f', 'office@mobilamoll.ro', NULL, NULL, NULL, 'terapeut', '2025-05-19 16:31:07.782315+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('49af0fde-1e09-4899-85d0-42f87dc62ad7', 'mihocbogdan96@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-16 08:24:19.280041+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('3497971b-b2c2-4a3a-9a42-420d8a26faec', 'kis.monica@yahoo.it', NULL, NULL, NULL, 'pending', '2025-05-13 08:18:59.044727+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('3bbd94c4-f929-4d5a-9621-721d396f75e3', 'psih.alinafr@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-16 09:27:39.790571+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('d0c25236-c4c4-4621-90a1-51f5f4d22d2b', 'carmen.talan@yahoo.com', 'CARMEN', 'TALAN', '0745625394', 'terapeut', '2025-05-15 17:55:54.455711+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('3e6b8532-e559-4bba-a913-9178fdb2a0bd', 'brifsorina@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-16 10:42:46.588915+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('d1792c86-294f-453e-ae1e-8474ab5553e3', 'mihaelastanciu999@gmail.com', NULL, NULL, NULL, 'pending', '2025-05-16 10:42:59.914355+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('13640682-e72c-448d-87a7-af45f1070498', 'vali_robu@yahoo.com', NULL, NULL, NULL, 'terapeut', '2025-05-16 12:24:25.720092+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('1f149689-c4dc-412f-8de6-9b25ee804842', 'nutzy_neiconi@yahoo.com', 'Nuți ', '0760191829', '', 'terapeut', '2025-05-22 12:43:42.424899+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('147fcc1b-10f1-4184-9d95-d09505d736fa', 'ionutrus231@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-22 13:45:54.456786+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('9945cd00-d2ba-494d-9852-4d9ceb75258e', 'lilea.emanuelacristina@yahoo.com', NULL, NULL, NULL, 'pending', '2025-05-19 05:57:40.599968+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('ab84c874-6fed-45be-9e1d-28da0a041149', 'elenadaniele_popa@yahoo.com', NULL, NULL, NULL, 'pending', '2025-05-19 07:53:38.669379+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('3add3342-f74c-49c7-985b-238208eebac5', 'terapeutdenisaelena@gmail.com', NULL, NULL, NULL, 'pending', '2025-05-19 08:56:43.547497+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('feea398b-e2c0-4217-be62-0da00ee5ac3b', 'complet.definit@yahoo.com', NULL, NULL, NULL, 'terapeut', '2025-05-19 11:58:16.390489+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('783f639b-1cab-407c-b1a9-fa510c00396d', 'biancanan1979@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-19 14:12:06.772932+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('dd8d0335-6696-4fb6-b186-31a0533d9587', 'adrianakarabuber79@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-19 15:10:24.342143+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('1bc4edd2-b5de-4b77-abb8-ffdad01efa4c', 'valentinfionut@yahoo.com', NULL, NULL, NULL, 'terapeut', '2025-05-19 15:11:30.335631+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('a1e1dcfe-893e-4c00-a4eb-29021630205d', 'ralucamihaela.alexandru1984@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-19 17:19:58.552882+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('6a70d9b5-4fb8-46f7-975b-5887fd4e47de', 'meri.velciu@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-21 07:26:09.464295+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('20d55537-6f54-41d6-98a6-474174099d17', 'carmenam_ro@yahoo.com', NULL, NULL, NULL, 'terapeut', '2025-05-20 21:37:36.151974+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('3b53ad8e-8faf-48c0-9628-f49ab70ded79', 'cosmo.coach.aag@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-21 10:38:35.524694+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('512c3b3b-0fa0-4659-8c0e-daccd911baa6', 'petruspop.catalina@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-16 09:10:55.499447+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('3a317800-976d-4277-a491-27d7962bb16b', 'suciaghialex@gmail.com', 'Alex', 'Boss', '0747282997', 'terapeut', '2025-05-20 05:30:09.442259+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('c7fc72ce-3614-4d3a-a617-c7b5aa2d9cd0', 'ageorgescu22@yahoo.com', NULL, NULL, NULL, 'pending', '2025-05-16 09:42:57.947674+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('52514d39-b9bc-42e3-8a24-69cd971a8414', 'carmenrauta68@yahoo.com', NULL, NULL, NULL, 'pending', '2025-05-16 11:02:28.952732+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('cf18dae6-9d04-4fa7-b284-f4ef1164a1ef', 'gorjy.ghy@gmail.com', 'Gorjan', 'Gheorghe', '', 'client', '2025-05-07 07:29:44.808165+00', '2025-05-23 00:00:00.454297+00', NULL, 'try', '2025-05-10 08:31:31.592+00', 10, 10, 0),
	('07a95865-754b-4fed-ae0a-d4b69c486190', 'carmendadu@gmail.com', 'CARMEN FLORINA', 'TARHON', '0766 86 58 54', 'terapeut', '2025-05-15 12:21:19.336849+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('f9a83a83-6324-46d1-9e75-3eddf8edd890', 'anghelescucodrutvictor@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-15 13:48:04.871555+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('622d14e0-2b33-4c8b-81d5-231a707fd100', 'pogaci2@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-20 07:02:39.024733+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('905b3a2e-780e-48f5-b37e-b335d9e97d4a', 'loryidu@yahoo.com', NULL, NULL, NULL, 'terapeut', '2025-05-19 15:48:15.429712+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('7b00956b-eafb-4d19-aed0-67dad9ab51ee', 'lica.mara.c02@gmail.com', '', '', '', 'terapeut', '2025-05-20 12:19:40.669847+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('89b950c9-a55e-4747-abf4-e403523289d4', 'iulia0475@gmail.com', NULL, NULL, NULL, 'pending', '2025-05-13 10:07:13.468869+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('f10db344-d6f0-4ae3-8ea0-4b1cb2a80894', 'psiholog.denisapopescu@gmail.com', 'Denisa', 'Popescu', '0724529344', 'terapeut', '2025-05-14 15:26:57.17706+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('aa3c7129-7b21-49e5-b099-19fa2ef0c95f', 'amaliacosma@gmail.com', 'Amalia', 'Tamaș', '0736948013', 'terapeut', '2025-05-13 08:19:48.394573+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', 'romanica.denisa@gmail.com', 'Denisa', 'Romanica ', '0720669210', 'terapeut', '2025-05-13 08:06:36.842427+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('e1ca682f-8dd7-4399-b622-4408513c1c11', 'psiho.adrianastiube@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-13 09:32:59.578022+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('a830c1a7-13ce-4c8f-96fa-4c7c7bb4085e', 'alexandru_georgian09@yahoo.com', NULL, NULL, NULL, 'terapeut', '2025-05-13 11:28:43.173984+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('12389e53-ab41-4ff5-90ee-c3593e2b84cc', 'andriescu.diana98@gmail.com', 'Diana', 'Andriescu', '0724594445', 'terapeut', '2025-05-13 14:50:53.653008+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('d707eee8-8de6-49fa-a4a6-00d79d6eded8', 'camelya98@yahoo.com', 'Camelia', 'Chirilă', '0744608085', 'terapeut', '2025-05-16 14:05:20.099947+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('398915d4-fa9b-430f-acd0-c44c6197221b', 'adrianamindful@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-22 12:56:47.003732+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('433c694d-a26a-44cb-84cc-45f84d7daf07', 'camyblaga@yahoo.com', NULL, NULL, NULL, 'terapeut', '2025-05-15 06:35:23.669949+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', 'sandu_elena1998@yahoo.com', NULL, NULL, NULL, 'terapeut', '2025-05-22 14:37:27.328009+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('1e8e19fd-7346-4d83-807e-404c01903baf', 'baciu.raul555@gmail.com', '', '', '', 'terapeut', '2025-05-20 23:50:00.56893+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('8e441edf-2d91-4551-a4e6-924316cd2090', 'contactandreigeorge@yahoo.com', NULL, NULL, NULL, 'terapeut', '2025-05-15 06:35:50.185833+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('c07e8742-9b26-4257-80d8-81ea920e3722', 'cbuzea30@gmail.com', 'Cristina', 'Buzea', '0771583393', 'terapeut', '2025-05-13 18:37:38.477262+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('1d4e4d74-493a-4758-a5e1-3229a81bae5d', 'inna.medeea.lupu@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-15 08:07:38.496471+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('459220a9-338b-4a45-8533-24789a3b1da7', 'miusimplu@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-18 13:24:52.912401+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('df1d2f97-8f64-4160-a909-9039e6619ae3', 'psihologandreeadianaion@gmail.com', 'Andreea-Diana', 'Ion', '0746657801', 'terapeut', '2025-05-13 07:49:31.625824+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('99556ce6-0304-4614-aeba-0c2f3d73a9f6', 'psiholog.kerteszreka@gmail.com', NULL, NULL, NULL, 'pending', '2025-05-21 07:49:50.789151+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('4240bff7-8190-4157-bc20-1b64f6e24ca8', 'hellosuciaghi@gmail.com', NULL, NULL, NULL, 'pending', '2025-05-21 08:18:03.738091+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('e9af8519-44db-48ee-9e9d-b7fe14ccc7a5', 'izabella.cete@gmail.com', 'Izabella ', 'Cete', '0744878007', 'terapeut', '2025-05-21 11:46:12.343058+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('1375c34c-1b05-438e-8f4f-eeb5f0d373f8', 'valentinpascariu85@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-15 09:53:23.130573+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('7617e0bf-ca39-47d8-a708-935afb8eaf87', 'laura_stan80@yahoo.com', NULL, NULL, NULL, 'terapeut', '2025-05-17 05:29:41.032012+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('6a5e67bb-c9b1-4b30-b860-3e4db36fcf2f', 'psiholog.malinalazar@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-15 16:04:01.063895+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('a7e4662b-0ae7-4687-98f5-a35387a707be', 'iozsiangelica@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-15 16:42:14.534043+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('76f53ea1-d6bf-4bf7-b88a-918e4062766e', 'secrets.of.life.f2p@gmail.com', '', '', NULL, 'terapeut', '2025-05-17 07:18:26.538618+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('7f541d24-fa47-444f-9ca4-f4f7bc3f4dde', 'ioanalexandruturcu@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-20 06:09:41.93819+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('072aa24d-bfc3-4b0c-93f2-1435906d8381', 'dianasimutm@gmail.com', 'Diana', 'Simu', '', 'terapeut', '2025-05-20 07:34:37.631903+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0),
	('cff988c4-74c7-4d89-8ea5-ca57af9c7a7a', 'renataiancupsiholog@gmail.com', NULL, NULL, NULL, 'terapeut', '2025-05-20 15:40:45.431497+00', '2025-05-23 00:00:00.454297+00', NULL, 'free', NULL, 10, 10, 0);


--
-- Data for Name: therapist_profiles; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO "public"."therapist_profiles" ("id", "specialization", "description", "experience", "education", "certifications", "price_per_session", "available_hours", "rating", "created_at", "updated_at", "therapy_types", "key_experience", "profile_image", "referral_code", "is_verified") VALUES
	('1d4e4d74-493a-4758-a5e1-3229a81bae5d', '{}', ' Sunt Inna Medeea Lupu, terapeut specializat în Programare Neuro-Lingvistică (NLP), radiestezie, regresii și consiliere spirituală. Misiunea mea este să ghidez oamenii către o înțelegere mai profundă a propriei vieți, să îi ajut să-și elibereze blocajele emoționale și să-și regăsească direcția și liniștea interioară.

Lucrez într-un mod integrativ, adaptând fiecare sesiune nevoilor unice ale fiecărei persoane. Folosesc instrumente moderne și metode intuitive pentru a crea un spațiu sigur, profund transformator, în care te poți reconecta cu tine însuți, cu resursele tale interioare și cu sensul personal.

Cu ce te pot ajuta:

Depășirea blocajelor emoționale sau mentale

Claritate în decizii și schimbări de viață

Echilibrare energetică prin radiestezie

Vindecare și înțelegere prin regresii în vieți anterioare sau amintiri timpurii

Reconectare cu Sinele autentic și ghidare spirituală

Indiferent unde te afli în călătoria ta, dacă simți că e timpul să-ți oferi un spațiu pentru vindecare și creștere, sunt aici să te însoțesc
', 2, ' Cred cu tărie că un terapeut este cu adevărat eficient atunci când îmbină cunoașterea teoretică cu experiența practică și cu o autentică dorință de a însoți oamenii în procesul lor de transformare.

Am absolvit Facultatea de Comunicare și Relații Publice, unde am învățat importanța ascultării active, a empatiei și a limbajului ca instrument de conectare și schimbare. Ulterior, am ales să îmi extind cunoștințele în direcția dezvoltării personale și spirituale, urmând formări care mi-au deschis perspective profunde asupra naturii umane.

Sunt Ambasador Internațional al programului de mindfulness „Search Inside Yourself”, o metodologie validată științific, care îmbină neuroștiința, inteligența emoțională și practicile de mindfulness.

De asemenea, am urmat cursuri de Programare Neuro-Lingvistică (NLP) și Radiestezie, instrumente valoroase pe care le folosesc în sesiunile mele pentru a sprijini procesul de autocunoaștere, echilibrare energetică și clarificare mentală.

Parcursul meu este o călătorie continuă de învățare și rafinare a prezenței, intuiției și abilităților terapeutice – totul în serviciul celor care aleg să lucreze cu mine.', '{}', 333.00, NULL, NULL, '2025-05-15 08:24:55.152297+00', '2025-05-15 08:24:55.152297+00', '{Mindfulness,"Consiliere Spirituală",NLP}', '', '', NULL, false),
	('8e441edf-2d91-4551-a4e6-924316cd2090', '{}', 'Descriere', 5, 'Descriere', '{}', NULL, NULL, NULL, '2025-05-15 10:04:39.96679+00', '2025-05-15 10:04:39.96679+00', '{"Consiliere Spirituală"}', '', '', NULL, false),
	('12389e53-ab41-4ff5-90ee-c3593e2b84cc', '{}', 'Psiholog clinician în supervizare și psihoterapeut CBT în formare. Abordarea mea în consiliere este eclectică, găsind împreună cu fiecare client calea cea mai potrivită de a aduce practicile științifice în peisajul individual al fiecărei persoane. 

     Cred cu tărie că există acea sursă de înțelepciune în fiecare dintre noi, care ne poate ghida în momente de tristețe profundă, deznădejde sau confuzie. Cu mine vei explora aceste tărâmuri pline de încercări într-un mod blând, empatic și cu cele mai bune instrumente. Eu însămi sunt prima persoană alături de care am trecut prin aceste tranziții, uneori de la dureri profunde către acceptare, mulțumire și optimism. Cunosc confuzia, furia, sentimentele grele și strânsoarea unor gânduri, precum și durerea resimțită câteodată în relațiile cu ceilalți. De aceea, în ședințele cu mine vei avea un spațiu sigur în care, mai întâi de toate, vei primi căldură și înțelegere.
', 2, 'Licență în Psihologie, Universitatea Babeș-Bolyai
Mrd. Consiliere și Intervenții Psihologice în Dezvoltarea Umană, Universitatea Babeș-Bolyai
În formare cognitiv-comportamentală
Atestat de liberă practică în Psihologie Clinică', '{}', 149.00, NULL, NULL, '2025-05-14 13:50:01.535669+00', '2025-05-14 13:50:01.535669+00', '{"Terapie Cognitiv-Comportamentală"}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/12389e53-ab41-4ff5-90ee-c3593e2b84cc-1747230602365.jpg', NULL, false),
	('f10db344-d6f0-4ae3-8ea0-4b1cb2a80894', '{}', 'În calitate de psiholog clinician și psihoterapeut cognitiv-comportamental în formare, am ca scop să sprijin fiecare client în identificarea și modificarea tiparelor de gândire care stau la baza dificultăților emoționale și comportamentale. Abordarea mea se bazează pe tehnici dovedite științific, care ajută la înțelegerea profundă a mecanismelor cognitive și la implementarea schimbărilor necesare pentru un comportament mai sănătos și echilibrat.

Mă concentrez pe crearea unui spațiu terapeutic sigur și deschis, în care persoanele pot explora gândurile și emoțiile lor fără frica de judecată, ajutându-le să-și regăsească echilibrul emoțional și să-și îmbunătățească modul în care răspund provocărilor. Fiecare sesiune este personalizată, luând în considerare specificitatea nevoilor și obiectivelor clientului.

Mă angajez într-un proces continuu de învățare și aprofundare a cunoștințelor pentru a integra cele mai noi cercetări și metode terapeutice în practica mea, astfel încât să ofer clienților cele mai eficiente soluții.', 1, 'Universitatea Transilvania din Brașov - Licență în Psihologie (2021-2024)
Universitatea sin București - Master în terapii cognitiv-comportamentale 
Formare de lungă durată în psihoterapie cognitiv-comportamentală - ATCCPR (2024 - prezent)', '{}', 150.00, NULL, NULL, '2025-05-14 17:40:28.503474+00', '2025-05-14 17:50:05.899471+00', '{Psihoterapeut}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/f10db344-d6f0-4ae3-8ea0-4b1cb2a80894-1747245004546.jpeg', NULL, false),
	('e2479383-7ba2-4290-beb7-6e8d08b52ee6', '{}', '', 8, '1. Bartolomeu Sandin

2. Caltosh marbot
Dofo - Banto Mixvam
2A. Lotosteu mangolantish', '{}', 400.00, NULL, NULL, '2025-04-28 09:44:01.000026+00', '2025-05-19 15:41:10.607289+00', '{Coaching,"Terapie prin Muzică"}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/e2479383-7ba2-4290-beb7-6e8d08b52ee6-1745941150454.png', 'SF59DB8R', true),
	('f9a83a83-6324-46d1-9e75-3eddf8edd890', '{Anxietate,Depresie,Traumă,OCD,"tulburare de personalitate",somatizare,"atac de panica"}', 'Folosesc metoda psihoterapiei psihanalitice sau psihodinamice, cum i se mai spune, ședințele având forma unui dialog în care pacientul se folosește de mine ca de un ghid pentru autoexplorarea psihicului său. 
Forma aceasta de psihoterapie pune accentul pe conflictele inconștiente care cauzează simptomatologia, aceasta fiind o formă de apărare a psihicului ca răspuns la unele evenimente semnificative din viața pacientului.', 2, 'Facultatea de Psihologie și Științele Educației Spiru Haret
Asociația de Consiliere și Psihoterapie Psihanalitică București
Psiholog clinician în supervizare
', '{"Psihoterapeut psihanalist","psiholog clinician"}', 200.00, NULL, NULL, '2025-05-17 07:15:29.711435+00', '2025-05-17 07:18:07.875151+00', '{Psihoterapeut,Psihanaliză}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/f9a83a83-6324-46d1-9e75-3eddf8edd890-1747466128645.jpg', 'NVUSQEP7', false),
	('e9af8519-44db-48ee-9e9d-b7fe14ccc7a5', '{"Terapie de cuplu","terapie emotionala",performanta,"anxietate si stres",mindfulness}', 'Sunt terapeut si Wingwave coach si sprijin oamenii sa ajunga la echilibru si sa-si creasca calitatea vietii prin tehnici ce coaching emotional. 
Sunt licentiata in Comunicare si Relatii Publice si Drept. Dupa multi ani de cautari, am ales domeniul de dezvoltare personala, studiind NLP Practitioner si Master, Wingwave Coaching, Psihologia Relatiei de Cuplu, Vindecare emotionala si terapia EMDR 
Momentan lucrez in sesiuni 1 la 1, de grup, dar organizez si workshopuri in format fizic si online, publice si corporate. 
Imi doresc sa impartasesc din experienta mea si sa sprijin pe oricine are nevoie sa ajunga la echilibru si la o viata implinita. 
Sunt membru Asociatia Romana de Programare Neuro-Lingvistica, formator acreditat ANC si Wingwave specialist cu acreditare ICF. 
Imi place sa ma dezvolt constant de aceea urmez in continuare diferite cursuri si specializari din domeniul meu. 
Sunt pasionata de sport, wellness si tot ce tine de o viata echilibrata.', 4, 'Facultatea de Comunicare si Relatii Publice -UBB 
Facultatea de Drept - Univ Ecologica Bucuresti 
Specializari: NLP Parctitiner, Master Advanced
Psihologia Relatiei de Cuplu 
Vindecare Emotionala niv 1 si 2 
Acreditare si membru Asociatia Romana de NLP 
Formator acreditat ANC 
Wingwave Coach Advanced acreditat ICF 
Trainer NLP ', '{ARONLP,ANC,"Besser-Siegmund Institut",ICF}', 250.00, NULL, NULL, '2025-05-21 12:05:22.541367+00', '2025-05-21 12:05:22.541367+00', '{"Terapie de Cuplu","Life Coach",Mindfulness,NLP}', 'Cu tehnica Wingwave lucrez cu emotiile, corpul si subconstientul, toate intr-o sesiune. Aceasta tehnica rezolva blocaje, emotii captive si chiar dureri fizice intr-un timp foarte scurt. ( ex. 4-8 sesiuni) 
Clientul a rezolvat durere lombara intr-o singura sedinta, durere post-operatie de ureche intr-o singura sedinta, acnee in 3 sedinte, tensiuni musculare, alergii si multe altele. ', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/e9af8519-44db-48ee-9e9d-b7fe14ccc7a5-1747829121312.jpeg', NULL, false),
	('65da1664-c0da-4c49-88c8-dce05acc1374', '{"Dezvoltare personala si autocunoastre",Anxietate,Psihogenealogie,"Terapii Relationale","Terapii Financiare","Terapii Spirituale"}', 'În practica mea terapeutică, împletesc psihologia clasică cu dimensiunea subtilă a ființei, integrând tehnici de consiliere, Reiki, radiestezie și ghidare spirituală. Fiecare ședință este personalizată, pentru că fiecare suflet are ritmul său, iar vindecarea autentică se întâmplă acolo unde omul este văzut, ascultat și înțeles în profunzime.

Lucrez cu oameni care simt că viața lor cere o schimbare, dar nu știu de unde să înceapă. Îi susțin să-și regăsească claritatea, echilibrul interior și încrederea în propria cale. Abordarea mea este una blândă, intuitivă și profund transformatoare, în care știința se întâlnește cu spiritul, iar rațiunea cu intuiția.

Valorile care îmi ghidează munca sunt:

Autenticitatea – Cred într-un spațiu sigur, în care poți fi tu, fără măști.

Respectul – Pentru fiecare poveste de viață și fiecare etapă a procesului de vindecare.

Compasiunea – Însoțesc cu blândețe și fără judecată fiecare pas pe drumul tău.

Conectarea – La sine, la ceilalți și la o dimensiune mai profundă a existenței.

Terapia pe care o ofer este unică prin îmbinarea mai multor niveluri de lucru: mental, emoțional, energetic și spiritual. Nu lucrez doar cu simptomul, ci cu cauza profundă, cu povestea sufletului tău. Îți ofer nu doar instrumente de vindecare, ci și o însoțire autentică în procesul tău de transformare interioară.

Am fost acolo. Am trăit pierderi, rătăciri, revelații și renașteri. Și din toate acestea am construit o cale pe care acum o împărtășesc cu cei care simt că e timpul să se întoarcă Acasă, în ei înșiși.

', 16, 'Sunt psiholog si terapeut Reiki de peste 16 ani. Am absolvit Facultatea de Psihologie si Stiinte ale Educatiei din cadrul UBB Cluj- Napoca, iar cursurile Reiki le-am urmat cu domnul doctor Ovidiu Dragos Argesanu,', '{"Licențiată în Psihologie
Terapeut Reiki – cu măiestrie în mai multe sisteme tradiționale și moderne de Reiki
Consilier spiritual – formare în ghidare spirituală și dezvoltare personală
Practician în radiestezie – cu experiență în lucrul cu energiile subtile"}', 200.00, NULL, NULL, '2025-05-22 08:15:28.266791+00', '2025-05-23 05:16:42.710971+00', '{"Terapie Holistică","Terapie de Familie","Life Coach",Mindfulness,"Consiliere Spirituală"}', 'Îmi amintesc o ședință cu un pacient care venise la mine copleșit de atacuri de panică și un nivel intens de anxietate. Trăia cu o teamă constantă, fără să înțeleagă exact de unde vine – iar corpul lui reacționa cu palpitații, nod în gât, senzația că "nu mai poate".
Am început prin a crea un spațiu sigur, în care să se poată exprima fără teamă de judecată. Am explorat împreună gândurile recurente, convingerile negative și tiparele adânc înrădăcinate, multe dintre ele moștenite din mediul familial.
Prin tehnici de conștientizare și lucru emoțional, am reușit să scoatem la lumină acele mesaje interioare care îi alimentau frica. În paralel, am lucrat energetic, folosind Reiki pentru a echilibra sistemul nervos și a liniști câmpul energetic. L-am ajutat să se reconecteze cu o sursă de liniște interioară și încredere, prin ghidare spirituală și exerciții de ancorare.
Pas cu pas, pacientul a început să înțeleagă că acele atacuri de panică erau de fapt strigăte ale sufletului său – cereri de ascultare și eliberare. În timp, starea lui s-a stabilizat, iar momentele de anxietate s-au redus considerabil, până la dispariție.
Această experiență mi-a reamintit cât de profundă este vindecarea atunci când lucrăm nu doar cu simptomele, ci cu întreaga ființă – minte, emoții, energie și spirit.
', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/65da1664-c0da-4c49-88c8-dce05acc1374-1747901727216.jpg', NULL, true),
	('53c97092-2634-4c47-ad83-808566dfbdcd', '{ADHD,Anxietate,Depresie,"Infertilitate Psihologica"}', 'Psiholog clinician sub supervizare, psihoterapeut in formare cognitiv-comportamentala, specializata pe evaluarea si interventia in ADHD la copii, adulti, adolescenti , membra a asociatiei ADHD Europe, membra a ESHRE (Asociatia Europeana de Reproducere Umana asistata) - pentru interventia psihologica in caz de infertilitate, Mindfulness si Life coach.', 1, '2006-2009- Universitatea Spiru Haret - facultatea de Psihologie si Stiintele Educatiei- specializarea Psihologie - Bucuresti
2024-prezent - Universitatea Spiru Haret - Master in Psihologie Clinica si Interventie psihologica - Brasov
2023- prezent - Formare in Psihoterapie Cognitiv Comportamentala
2025 - Drept de libera practica - psiholog clinician sub supervizare (cod 34223)', '{"Psiholog clinician sub supervizare","cursuri de formare continua - Evaluarea si interventia in ADHD","Life coach"}', 150.00, NULL, NULL, '2025-05-19 09:59:25.07178+00', '2025-05-19 10:05:39.308904+00', '{"Life Coach","Terapie Cognitiv-Comportamentală",Mindfulness}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/53c97092-2634-4c47-ad83-808566dfbdcd-1747648762351.jpeg', NULL, false),
	('3a317800-976d-4277-a491-27d7962bb16b', '{Gg}', 'Ff', 5, 'Gg', '{Bhh}', 55.00, NULL, NULL, '2025-05-21 15:27:04.476691+00', '2025-05-21 15:43:46.953486+00', '{Psihoterapeut}', 'Ffft', '', NULL, true),
	('ae26134b-38c8-4748-8770-5b73d79cae08', '{"Nutritie si Dietetica",Anxietate,Depresie,"Dezvoltare personala","Relatii familiale si de cuplu"}', 'Profesez ca terapeut de anul trecut, de cand mi-am obtinut acreditarea internationala de psihoterapeut RTT - Rapid Transformational Therapy. Terapia de transformare rapidă (RTT) combină principiile hipnoterapiei, psihoterapia, programarea neuro-lingvistică (NLP), terapia cognitiv comportamentală (CBT) și neuroștiința. Sunt foarte multumita de rezultatele acestei forme de terapie, intrucat funcționează cu mintea subconștientă. Subconștientul, numit și creierul emoțional, este o resursă extraordinară și practic, este ca un seif unde se păstrează tot ceea ce ai învățat si acumulat de-a lungul vietii. Experiențe care au modelat modul în care te simți în legătură cu viața în general și de ce reacționezi la anumite lucruri în special. 
Consider ca in practica mea am reusit mereu sa gasesc o metoda cat mai eficienta si potrivita de a ghida clientul spre constientizare si vindecare. Incerc mereu sa ma mulez dupa cerintele si nevoile clientului si sa aleg tehnica potrivita in functie de caz, persoana, gravitatea situatiei.
', 1, 'Certificare de Terapeut RTT
Certificare de Hipnoterapeut 
- amandoua recunoscute international

', '{"Certificare Terapeut RTT
Certificare Hipnoterapeut"}', 250.00, NULL, NULL, '2025-05-21 20:45:17.153748+00', '2025-05-21 20:45:17.153748+00', '{Psihoterapeut,Hipnoză,"Terapie Cognitiv-Comportamentală","Terapie de Cuplu",Psihanaliză,Nutriție,"Life Coach",Mindfulness}', 'O experienta care mi-a confirmat cu toata certitudinea dorinta pe care o am de a practica in acest domeniu a fost cu o clienta abuzata sexual in copilarie, de verisorul ei. O experienta extrem de traumatizanta, pe care cu timpul a suprimat-o. Cand am avut interactiunea cu aceasta clienta, ea avea deja 3 copiii si era casatorita cu un barbat care la randul sau, o abuza atat sexual cat si emotional. Facand regresie si mai apoi conexiunea dintre momentul prezent si convingerile si experientele acumulate in copilarie, a ajuns la constientizarea ca nu mai poate continua aceasta relatie. A reusit pe parcursul a 7 luni de lucrat impreuna sa divorteze, sa isi refaca relatiile cu copiii sai si totodata a inceput sa lucreze in domeniul in care si-a dorit de cand era tanara.', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/ae26134b-38c8-4748-8770-5b73d79cae08-1747860315525.JPG', NULL, false),
	('d707eee8-8de6-49fa-a4a6-00d79d6eded8', '{anorexie,ortorexie,bulimie,denutriție,"mâncat emoțional","mâncat compulsiv","sindromul premenstrual",PCOS,amenoree,"menstruații neregulate","dominanță de estrogen","diabet și insulinorezistență",gastrită,"reflux gastroesofagian","colon iritabil","boala Crohn",rectocolită,"deficiențe nutriționale","intoleranțe alimentare",alergii,"constipație/diaree cronice","oboseală cronică","balonare cronică","infecții recurente și imunitate scăzută","Obezitate și kilograme în exces",acnee,depresie,anxietate}', 'Nutriție, psihonutriție, dietoterapie, educație pentru un stil de viață general sănătos și echilibrat ', 11, 'Licență în nutriție și dietetică 
Master în nutriție clinică și comunitară
Experiența de peste 10 ani
Experiența personală în domeniul de lucru (anorexie, bulimie, mâncat compulsiv, etc)', '{}', 250.00, NULL, NULL, '2025-05-19 09:37:54.958106+00', '2025-05-22 11:42:27.349855+00', '{Dietetician,Nutriție,"Life Coach","Terapie Holistică"}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/d707eee8-8de6-49fa-a4a6-00d79d6eded8-1747647474025.jpeg', NULL, false),
	('07a95865-754b-4fed-ae0a-d4b69c486190', '{"•	Anxietății și fobiilor •	Tulburărilor de somn •	Dependențelor (fumat","alimentație compulsivă) •	Stimei de sine scăzute •	Obiceiurilor nesănătoase •	Îmbunătățirea relațiilor interpersonale •	Dezvoltarea personală și profesională •	Dezvoltarea unor strategii sănătoase de coping •	Crearea unui plan personalizat de recuperare"}', 'Abordarea mea terapeutică este una integrativă, personalizată, care îmbină psihoterapia integrativă cu hipnoza clinică și intervenții specifice în adicții. 

', 10, 'Educație și formare profesională:

1. Facultatea de Științe Socio-Umane - Universitatea LUCIAN BLAGA din Sibiu
Specializarea: Psihologie
Perioadă: 2004-2008

2. Formare în Psihoterapie Integrativă – Asociația Română de Psihoterapie Integrativă
 Perioadă: 2008 - 2012

3. Formare în Hipnoză Clinică Directă - Escuela Oficial de Hipnosis Clinica din Spania
Perioadă: mai 2024 – octombrie 2024

', '{"Certificat de consilier în adicții – ANC
Certificat de consilier dezvoltare personală – ANC
Certificat în hipnoză clinică – Escuela Oficial de Hipnosis Clinica","Spania
Formare în psihoterapia integrativă – ARPI"}', 250.00, NULL, NULL, '2025-05-15 12:31:18.87353+00', '2025-05-15 13:12:40.665349+00', '{Psihoterapeut,Hipnoză}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/07a95865-754b-4fed-ae0a-d4b69c486190-1747314759948.jpg', NULL, false),
	('8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8', '{Anxietate,"stima de sine scazuta",fobii,trauma}', 'Sunt psiholog clinician in supervizare acreditat de Colegiul Psihologilor si psihoterapeut integrativ acreditat FRP.
De asemenea, practic life-coaching-ul din anul 2021.', 5, 'Facultatea de Psihologie si Stiintele Educatiei, Bucuresti- 2021-2024
Formare in psihoterapie integrativa 2020-2023
Drept de libera practica de la Colegiul Psihologilor in psihologie clinica 2024
Life coach acreditat 2020
', '{"Atestat in psihologie clinica
Atestat psihoterapeut integrativ 
Atestat life coach"}', NULL, NULL, NULL, '2025-05-19 15:01:10.81761+00', '2025-05-19 15:09:00.769498+00', '{Psihoterapeut}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8-1747666869462.jpg', NULL, false),
	('1e8e19fd-7346-4d83-807e-404c01903baf', '{Fitness,Box,TRX}', 'Lucrez din Pasiune

Speaker la CNIS ( Conventia Internationala Sovata )



Cu stima,
Tovarasul Bartos', 7, 'Palo Santo, Scoala multa

scoala 2, scoala 3', '{Dodolito,"Bartosjh santa",fofo,"soso

dodo fofo dodo soso"}', 333.00, NULL, NULL, '2025-05-21 00:00:49.966866+00', '2025-05-23 05:16:10.730311+00', '{Nutriție}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/1e8e19fd-7346-4d83-807e-404c01903baf-1747785649870.jpg', 'A74V9PW0', true),
	('49af0fde-1e09-4899-85d0-42f87dc62ad7', '{"Depresie Anxietate.Stres.Trauma"}', 'Sunt psiholog clinician și mă formez în psihoterapie cognitiv-comportamentală, o metodă bazată pe dovezi, care ajută oamenii să înțeleagă și să schimbe tiparele de gândire și comportament care le provoacă suferință. În același timp, aduc în proces și perspectiva dobândită din experiența mea cu dezvoltarea personală și explorarea dimensiunii spirituale.

Cred într-o abordare echilibrată – una care să combine claritatea rațională cu empatia și autenticitatea. Fie că vorbim despre gestionarea anxietății, creșterea stimei de sine sau găsirea direcției în viață, creez un spațiu sigur în care oamenii pot să se descopere, să se vindece și să evolueze în ritmul lor.', 1, 'Am absolvit ciclul de licență în 2023, voi absolvi la începutul lunii iulie ciclul de masterat. Sunt psiholog clinician atestat din februarie 2024. Tot de atunci sunt în supervizare. Am împărțit cabinetul cu supervizarea mea o perioada, ceea ce m-a ajutat sa învăț multe tehnici si abordări într-un timp scurt, ea fiind un terapeut foarte bun. Am multa experienta si din voluntariatele la care am participat.', '{PsihologClinician}', 150.00, NULL, NULL, '2025-05-16 08:49:26.469412+00', '2025-05-16 08:51:38.368301+00', '{"Terapie Cognitiv-Comportamentală","Life Coach","Consiliere Spirituală"}', 'Este vorba despre o persoana care s-a prezentat cu o trauma după o intervenție chirurgicala. De la momentul intervenției pana sa începem sa lucram au trecut 2 ani. Petrecea mult mai mult timp în minte decat in realitate, creând scenarii si avand foarte multe ganduri. Am reușit sa integram evenimentul traumatic, sa rezolvam problemele cu somnul si sa înceapă sa isi creeze un drum cu sens în viață ', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/49af0fde-1e09-4899-85d0-42f87dc62ad7-1747385363731.jpg', NULL, false),
	('3e6b8532-e559-4bba-a913-9178fdb2a0bd', '{Dezvoltare-personala-anxietate-depresie-terapie-sistemica-individuala-familie-cuplu}', '', 2, 'Sunt licentiata in psihologie din 2011, cu experienta initial ca people manager in multinationale, resurse umane si psiholog in ONG, recent avand clienti ca si Consilier dezvoltare personala in practica privata ', '{Atestat-psihologie-clinica-atestat-consilier-dezvoltare-personala-inprezent-psihoterapeut-in-formare-sistemica}', 200.00, NULL, NULL, '2025-05-16 10:48:53.834649+00', '2025-05-16 10:48:53.834649+00', '{Psihoterapeut,"Life Coach","Terapie de Cuplu","Terapie de Familie"}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/3e6b8532-e559-4bba-a913-9178fdb2a0bd-1747392526420.jpg', NULL, false),
	('13640682-e72c-448d-87a7-af45f1070498', '{Anxietate,depresie,"atacuri de panica",fobii,"tulburări de dinamica sexuala"}', 'Psiholog clinician 
Psihoterapie psihanalitica copil, adolescent,  și adult
Psihologie aplicata in domeniul siguranței naționale ', 3, 'Facultatea de Psihologie 
Master Psihologie clinica hipnoza și intervenții de scurta durata', '{"Psiholog clinician 
Interventii la copii cu TSA"}', NULL, NULL, NULL, '2025-05-16 12:44:14.299244+00', '2025-05-16 18:32:14.86921+00', '{Psihoterapeut,"Terapie de Familie","Terapie de Cuplu",Psihanaliză}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/13640682-e72c-448d-87a7-af45f1070498-1747399451163.jpg', NULL, false),
	('76f53ea1-d6bf-4bf7-b88a-918e4062766e', '{}', '', NULL, '', '{}', NULL, NULL, NULL, '2025-05-17 09:06:13.114259+00', '2025-05-17 09:06:13.114259+00', '{Numerolog}', '', '', NULL, false),
	('0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', '{Anxietate,depresie,stres,"tulburări alimentare","atacuri de panică","consiliere vocațională."}', 'Bun venit!

Mă bucur că ești aici. Faptul că ai ajuns în acest spațiu este deja un pas important – și curajos – spre tine.

Sunt psiholog clinician și terapeut în formare în psihoterapie cognitiv-comportamentală, iar în ședințe aduc și elemente din Terapia prin Acceptare și Angajament (ACT) și mindfulness. Cred într-o relație terapeutică bazată pe siguranță, empatie și autenticitate – un loc unde poți fi tu, fără judecată.

Lucrez cu oameni care se confruntă cu depresie, anxietate, stres, dificultăți emoționale sau relaționale  sau care pur si simplu se confrunta cu dificultăți de orice fel.
Te aștept la o ședință!
www.psihologromanicadenisa.blog ', 1, 'Licenta in Psihologie - la Universitatea de Vest, Facultatea de Sociologie și Psihologie din Timișoara.
Master în Psihologie Clinică și Psihoterapie Cognitiv-Comportamentală la Universitatea de Vest, Facultatea de Sociologie și Psihologie din Timișoara.

Supervizare în Psihologie Clinică din 2022.

Formare continuă în terapie cognitiv-comportamentală.', '{"Atestat în Psihologie Clinică

Formare continua în evaluarea personalității."}', 150.00, NULL, NULL, '2025-05-17 10:46:59.609359+00', '2025-05-17 10:54:49.783677+00', '{Psihoterapeut,"Terapie Cognitiv-Comportamentală","Life Coach",Mindfulness}', '-', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca-1747478818112.jpg', '3O3WC888', false),
	('459220a9-338b-4a45-8533-24789a3b1da7', '{}', '', NULL, '', '{}', NULL, NULL, NULL, '2025-05-18 13:25:17.272042+00', '2025-05-18 13:26:23.466577+00', '{"Consiliere Spirituală"}', '', '', 'V6N1GCZ3', false),
	('7617e0bf-ca39-47d8-a708-935afb8eaf87', '{"Traumă  Anxietate  Depresie  Stima de sine  Relații de cuplu  Relația părinte-copil  Răni din copilărie  Coaching și obiective personale  Vindecare transgenerațională  Dezechilibre emoționale  Dezechilibre energetice  Feminitate și sexualitate  Comunicare și exprimare de sine  Manifestare și legea atracției  Crize de viață și regăsirea sensului  Autocunoaștere și dezvoltare personală  Sprijin spiritual și reconectare interioară"}', 'Sunt Laura Stan – terapeut și coach cu o abordare integrativă, profund umană și spirituală. Mă ghidez după convingerea că fiecare om are în el resursele necesare pentru vindecare și transformare, iar rolul meu este să creez un spațiu sigur, cald și conținător în care acest proces să aibă loc natural, în ritmul propriu al clientului.

Lucrez preponderent cu femei, între 18 și 70 de ani, dar abordarea mea sprijină indirect și relațiile lor cu bărbații, partenerii, copiii, părinții sau colegii. Multe dintre cliente vin către mine cu dificultăți în relații, lipsă de încredere în sine, răni din copilărie, probleme de comunicare, anxietăți sau blocaje emoționale care le împiedică să se manifeste autentic. Sunt și mame care caută sprijin în relația cu copiii lor, femei aflate în criză de sens sau care vor pur și simplu să se pună pe primul loc.

Integrez instrumente din psihoterapie integrativă, coaching, hipnoză regresivă, Theta Healing, constelații familiale sistemice, terapia prin artă, EFT, numerologie, radiestezie, Reiki și alte practici energetice. De asemenea, folosesc meditații ghidate, ritualuri cu energia lunii, lucrul cu simboluri, oracole și tehnici intuitive, adaptate la nevoile fiecărei persoane.

Cred într-o vindecare profundă și blândă, care uneori are loc în tăceri, alteori în descărcări emoționale puternice, dar întotdeauna cu sens.

Valori care mă ghidează
Cred în confidențialitate deplină, empatie autentică, prezență conștientă, respect pentru ritmul unic al fiecărei persoane, dar și în puterea blândeții de a deschide porți spre adevăruri interioare. Alte valori esențiale pentru mine sunt integritatea, susținerea fără judecată, smerenia, onorarea poveștii de viață a clientului și credința că fiecare proces este sacru.

Ce mă face diferită

Îmbin știința și intuiția, psihologia și spiritualitatea, logica și energia. Nu ofer doar o ședință de terapie – ofer un spațiu viu, sigur, conținător, în care fiecare femeie se poate regăsi, elibera și reconstrui dintr-un loc de autenticitate. Intuiția dezvoltată, prezența blândă, experiența vastă în multiple metode terapeutice și respectul profund față de unicitatea fiecărui suflet fac din fiecare întâlnire o experiență de transformare profundă.', 6, '
Studii universitare, formări și workshopuri relevante

Licențiată în Inginerie (Universitate Tehnică)

Studentă în formare continuă – Psihoterapie Integrativă (ARPI – Asociația Română de Psihoterapie Integrativă)


Formări complementare și certificări:

Coach acreditat – Academia de Coaching Alina Șuțu

Theta Healing® Practitioner – certificată în mai multe niveluri (Basic, Advanced, Dig Deeper, Manifesting and Abundance etc.)

Hipnoză regresivă – regresii în vieți actuale și anterioare

Terapeut Reiki – inițieri în Reiki Usui și Reiki Karuna

Facilitator constelații familiale sistemice cu obiecte

EFT – Tehnici de eliberare emoțională

Radiestezie terapeutică și spirituală

Consilier pentru dezvoltare personală – acreditat

Formare în terapia prin artă – lucrul cu simboluri, desen, modelaj, pictură

Cursuri de numerologie aplicată și autocunoaștere prin arhetipuri


Workshopuri și retreat-uri:

Participare și co-facilitare în retreaturi de dezvoltare personală și spirituală (România și Bali)

Workshopuri tematice pe feminitate, vindecarea copilului interior, relații, comunicare și manifestare

Participare activă în formări și grupuri de practică avansată (constelații familiale, coaching, regresii, psihoeducație)', '{"Formare în curs – Psihoterapie Integrativă
Studentă în formare continuă în cadrul Asociației Române de Psihoterapie Integrativă (ARPI)","program acreditat de Colegiul Psihologilor din România

Coach acreditat – diplomă recunoscută și atestată ANC (Autoritatea Națională pentru Calificări)","obținută în cadrul Academiei de Coaching Alina Șuțu

Consilier pentru dezvoltare personală – atestat ANC (Cod COR 242324)

Practician Theta Healing® – certificat internațional emis de THInK – ThetaHealing Institute of Knowledge
(niveluri: Basic DNA","Advanced DNA","Dig Deeper","Manifesting & Abundance","You and the Creator etc.)

Practician hipnoză regresivă – certificat de formare în regresii în vieți curente și anterioare

Facilitator constelații familiale sistemice cu obiecte – certificat de formare (program în desfășurare)

Terapeut Reiki Usui și Karuna – inițieri și certificări în Reiki tradițional și Reiki Karuna

Practician EFT (Emotional Freedom Techniques) – certificat de absolvire curs

Practician radiestezie terapeutică și spirituală – certificat de formare în lucrul cu pendulul","biometre și testări energetice

Formare în terapia prin artă – certificat de participare în lucrul terapeutic cu simboluri",desen,pictură,"modelaj

Formare în numerologie aplicată – certificat de absolvire în autocunoaștere și analiză numerologică"}', 300.00, NULL, NULL, '2025-05-19 05:45:27.267076+00', '2025-05-19 05:48:58.055369+00', '{"Life Coach","Consiliere Spirituală","Terapie Cognitiv-Comportamentală",Hipnoză,"Terapie Holistică",Psihoterapeut,"Terapie de Cuplu",Psihanaliză,Numerolog}', 'Unul dintre cele mai marcante momente din parcursul meu profesional a fost întâlnirea cu o femeie care, deși trecuse de 40 de ani, purta încă în corp și în suflet durerea copilului nedorit. Într-o sesiune de hipnoză regresivă, a ajuns spontan într-o amintire de la 4 luni, în care mama o ținea în brațe doar pentru câteva secunde, spunând apoi că e „prea grea” și o lăsa jos. În acel moment, s-a activat o rană profundă de respingere – o senzație de neapartenență, de neiubire, care o însoțea de-o viață.

Această femeie se lupta cu kilograme în plus, diabet și hipotiroidism. Mai profund decât orice diagnostic era însă furia – pe părinți, pe sora ei, pe copilul interior care „nu a fost suficient de bun” ca să fie iubit. Am lucrat împreună cu blândețe, prin regresie, constelații familiale cu obiecte și descărcări din Theta Healing pentru a-i aduce în corp permisiunea de a se iubi, de a fi văzută, de a merita vindecarea.

A fost un moment de transformare nu doar pentru ea, ci și pentru mine. M-a învățat cât de mult poate ține corpul amintirea unei priviri sau a unui gest, și cât de profundă poate fi eliberarea când cineva este văzut cu adevărat, fără judecată. A fost dovada vie că atunci când clientul se simte în siguranță, procesul de vindecare curge natural, iar transformarea apare din interior.', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/7617e0bf-ca39-47d8-a708-935afb8eaf87-1747633527344.png', 'QTB7MTU6', false),
	('a6f658f8-149d-4063-b1d9-c54105f03392', '{Mindfulness,"creșterea stimei de sine",feminitate,nlp,"gestionarea stresului."}', 'Sunt Life coach autorizat/ coach de feminitate, am studiat si parcurs un program de NLP.
Lucrez alături de femei în sesiuni 1 la 1 sau sesiuni de grup .
Am susținut și organizat o serie de conferințe/ workshop cu o tematica de interes pentru femei, denumit generic " Manifestul Feminității ".
Am lucrat cu tineri pentru identificarea valorilor, a oportunitilor profesionale , bazele încrederii în sine. 
În practica mea de lucru cu femeile le ajut să-și identitate unicitatea lor, să-și recladeasca echilibrul interior  prin programul pe care l-am creat denumit " Feminină în Business și Carieră ".
Sunt parte a progresului monitorizat atent alături de femei în sesiuni de coaching 1 la 1 prin exerciții de coaching si NLP.
Ajut femeile să-și identifice valorile, nevoile, să-și crească stima de sine prin exerciții de coaching ce pot deschide multiple conștientizări menite să le elimine blocajele din viața lor.
Parte a unui proces de dezvoltare personală, susțin acest proces temeinic monitorizat și susținut prin expertiza mea, programele de formare în calitate de life coach. ', 2, 'Coach autorizat in baza Certificatului emis de către Ministerul Muncii și Solidarității Sociale în anul 2023, specialist în activitatea de coaching. 
Absolventa a Academiei de Coaching si NLP din cadrul companiei Nine WAYZ.
În prezent studenta a Facultății de Psihologie ', '{Coach,NLP,"formator/ trainer"}', 200.00, NULL, NULL, '2025-05-19 10:21:39.188897+00', '2025-05-19 10:38:14.095325+00', '{"Life Coach",NLP,Mindfulness}', 'Cele mai extraordinare momente de revelație profesională și nu numai din activitatea mea, sunt acelea în care, în cadrul discuțiilor din sesiuni femeile își recladesc proprie identitate, dar mai mult decât atât, infloresc în propria viață. 
Zâmbetul, eliberarea ,acceptarea sunt definitorii pentru clădirea identității lor, iar exact aceste aspecte sunt surprinse în sesiunile avute și creează un context de dezvoltare personală. 
La finalul unui program de feminitate una dintre cliente mi-a mărturisit faptul că, lucrând alături de mine a integrat liniștea în viața ei, a învățat ce înseamnă să fii o Femeie în adevăratul sens al cuvântului și ce bine se simte acest aspect. ', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/a6f658f8-149d-4063-b1d9-c54105f03392-1747650097836.jpg', 'QITLTEU9', false),
	('feea398b-e2c0-4217-be62-0da00ee5ac3b', '{Anxietate,depresie,"atacuri de panica",relatii,"dezvoltare personala"}', 'Ma numesc Ana-Maria Pascuta și sunt Psiholog Clinician si Psihoterapeut cu o aboordare Cognitiv-comportamentala.
Sunt Licentiata a Facultatii de Medicina si a Facultatii de Psihologie si Stiinte ale Educatiei din Cluj-Napoca.
Iubesc viata si tot ce inseamna fiinta vie. 
Imi iubesc profesia si am ales sa practic psihoterapia deoarece am inteles ca omul are nevoie de mult mai mult decat hrana si caldura fizica. Am fost dintotdeauna o persoana foarte deschisa spre lume, om si viata.
Mi-am dorit dintotdeauna sa pot  aduce un zambet pe fata celorlalti.
Aceasta dorinta provine din propria mea experienta de viata si din suferinta pe care am vazut-o dar nu am putut sa o schimb in viata unor fiinte semnificative din viata mea. 
Cred ca psihoterapia este o arta si tocmai de aceea necesita o dezvoltare permanenta si continuua.Mi-am dedicat mai mult de 20 ani citind, studiind, invatand in mod constant din fiecare experienta atat personala cat si din interactiunile cu ceilalti.
Pot ajuta atat in probleme de anxietate, depresie, atacuri de panica dar totodata si in zona de autocunoastere, dezvoltare personala si relatii.', 10, 'Universitatea de Mediciana si Farmacie IULIU HATIEGANUL din Cluj-Napoca, Specializarea Recuperare medicala
Facultatea de Psihologie si Stiinte ale Educatiei din Cluj-Napoca, Formare Psihoterapie cognitiv-comportamentala
Formare Dezvoltare personala ', '{"Licenta Universitatea de Medicina si Farmacie Iuliu Hatieganul din Cluj-Napoca
Licenta Universitatea Babes- Bolyai","Facultatea de Psihologie si Stiinte ale Educatiei"}', NULL, NULL, NULL, '2025-05-19 12:18:44.69746+00', '2025-05-19 12:18:44.69746+00', '{"Terapie Cognitiv-Comportamentală",Psihoterapeut,"Terapie de Cuplu","Life Coach","Consiliere Spirituală","Terapie de Familie"}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/feea398b-e2c0-4217-be62-0da00ee5ac3b-1747657123699.jpg', NULL, false),
	('dd8d0335-6696-4fb6-b186-31a0533d9587', '{}', '„Vindecarea nu înseamnă doar să îndepărtezi durerea, ci să redescoperi cine ești dincolo de ea.”
Sunt Adriana Karabuber, hipnoterapeut, NLP Practitioner, Coach și ghid în procesul profund de reconectare cu sinele.
Lucrez cu oameni care simt că viața lor a ajuns într-un blocaj – emoțional, mental sau spiritual – și care își doresc nu doar să supraviețuiască, ci să se transforme.

Ce ofer în cadrul ședințelor mele
 - Hipnoterapie – pentru eliberarea traumelor, stresului, dependențelor emoționale, autosabotajului și programelor inconștiente care te țin pe loc
- NLP (Programare Neuro-Lingvistică) – pentru rescrierea gândirii, schimbarea tiparelor limitative și activarea resurselor personale
- Coaching transformațional – pentru obiective clare, asumare și evoluție conștientă
- Consiliere spirituală și introspecție – pentru reconectarea cu vocea ta interioară, liniște și sens
- Terapie holistică – în care mintea, corpul și sufletul sunt privite ca un întreg

Abordarea mea

Fiecare om este o lume unică. De aceea, sesiunile mele sunt personalizate și ghidate intuitiv, cu blândețe, prezență și profunzime.

Integrez tehnici științifice validate (hipnoză, NLP, coaching) cu abordări subtile și spirituale, pentru cei care simt chemarea spre o vindecare mai profundă – dincolo de cuvinte.', 3, 'Un drum de creștere, vindecare și sens

Am început drumul meu profesional studiind Științe Economice la Universitatea din Bacău, însă în paralel am simțit mereu chemarea profundă de a înțelege sufletul uman și mecanismele subtile ale minții.

De-a lungul anilor, am urmat o serie de cursuri și formări în domeniul dezvoltării personale, spirituale și terapeutice, care astăzi îmi permit să ofer sesiuni complexe, integrate și profund transformatoare:Formări și certificări:
- Facultatea de Științe Economice, Universitatea Bacău
- Participare la numeroase workshopuri de dezvoltare personală, inteligență emoțională și autocunoaștere
- Reiki – nivel II, terapie energetică de echilibrare și armonizare
- Theta Healing – nivel începător și intermediar – lucrul cu subconștientul, credințele și vindecarea emoțională profundă
- NLP Practitioner – 2018, la Aripile Transformării
- NLP Master – 2021, la Aripile Transformării
- NLP Master Coach – 2023, la Aripile Transformării
- Hipnoză Practitioner – formare în Spania, cu profesor Matei Șandor
- Curs de traumă (în desfășurare) – Spania
- Curs de Hipnoză pentru Avansați – în derulare, aprofundare continuă

În munca mea, îmbin:
- tehnici validate științific (NLP, hipnoză, coaching)
- metode energetice și intuitive (Reiki, Theta Healing)
- abordări blânde dar profunde pentru vindecarea traumei și reconectarea cu sinele autentic

Cred cu tărie că fiecare om are în el toate resursele necesare pentru a se vindeca și a-și transforma viața. Eu sunt aici să creez spațiul, să susțin procesul și să reflect lumina interioară a fiecărui client care își dorește să revină acasă – în propria ființă.', '{}', 300.00, NULL, NULL, '2025-05-19 15:32:53.204708+00', '2025-05-19 15:44:54.944223+00', '{Hipnoză,NLP,Mindfulness,"Life Coach","Terapie Holistică","Consiliere Spirituală"}', 'Caz real: Cum hipnoza a ajutat-o pe mama mea să-și regleze tensiunea arterială fără medicamente

Una dintre cele mai apropiate și profunde experiențe din practica mea de hipnoterapie a fost cu propria mea mamă.

De ani de zile se confrunta cu tensiune arterială foarte mare, constant în jur de 170 mmHg, iar în momentele de supărare sau stres, urca rapid și periculos la 190. Medicamentele nu făceau mare diferență, iar corpul ei devenea tot mai tensionat și epuizat.

Am decis să încep lucrul cu ea prin hipnoză blândă și ghidată, cu accent pe:

- relaxarea profundă a corpului,
- reglarea ritmului respirator,
- detensionarea emoțională și accesarea unui sentiment de siguranță interioară.

Am făcut împreună sesiuni constante, timp de 3 săptămâni – simple, dar profunde. Nu am folosit sugestii rigide, ci am ghidat corpul și mintea către calm, încredere și echilibru.

      Rezultatul?
La finalul celor 3 săptămâni, tensiunea i-a scăzut natural la 140 (14) – fără medicație.
Și, cel mai important, starea ei generală s-a schimbat:
mai calmă, mai prezentă, mai împăcată.

Această experiență mi-a confirmat din nou că:

Mintea influențează corpul. Iar calmul mental este cheia vindecării fizice.
Dacă și tu te confrunți cu tensiune crescută, anxietate sau blocaje emoționale,
hipnoza te poate ajuta să-ți regăsești echilibrul din interior spre exterior.', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/dd8d0335-6696-4fb6-b186-31a0533d9587-1747668772285.jpeg', '7AY4HJWK', false),
	('905b3a2e-780e-48f5-b37e-b335d9e97d4a', '{}', 'Sunt adepta unei terapii complete :a corpului ,a mintii si a sufletului. 
Pentru terapia corpului ,am studiat  si aplicat Noua Medicina Germana si Recoll Healling.
Pentru terapia mintii ,am studiat si practicat hipnoza.
Pentru terapia sufletului ,am studiat si practicat Theta Healling.
 Urmand aceste trei abordari, m-am vindecat singura ,fara nici un tratament medicamentos ,de psoriazis.', 3, 'Facultatea de Biologie (profesia de baza).
Expert in tehnici de hipnoza.
Studiu individual Noua Medicina Germana si Recoll Healling.
Terapeut Theta Healing (nivel baza,avansat si sapare profunda)
Consilier de dezvoltare personala', '{}', 200.00, NULL, NULL, '2025-05-20 08:05:43.69409+00', '2025-05-20 08:05:43.69409+00', '{Hipnoză,"Terapie Holistică","Consiliere Spirituală"}', 'eu m-am vindecat de psoriazis .', '', NULL, false),
	('622d14e0-2b33-4c8b-81d5-231a707fd100', '{Anxietate,Depresie,"Atacuri de panică",Dependente,"Controlul greutății","Invatare rapida","Terapia Durerii","Vindecarea traumei","Consiliere schimbare și Transformare","Optimizarea relațiilor."}', 'Life coaching, Time Line Therapy ( R)( cel mai rapid și eficient proces de vindecare, bazat pe conceptul de linia timpului) , NLP ( Programare Neuro- Lingvistică) hipnoză, certificate la nivel de master, plus acreditarea ca și consilier dezvoltare personală sunt unelte puternice pentru schimbarea comportamentală și dezvoltarea personală. 
Time Line Therapy(R) eliberează emoțiile negative din trecut, facilitează o eliberare emoțională rapidă și durabilă. Acestea conduc la un proces rapid și eficient de vindecare pe o paletă largă de afecțiuni de la depresie, anxietate, atacuri de panică  etc. dependențe și alt gen de afecțiuni , pe care se intervin conform unui " protocol al durerii".
NLP explorează modul în care gândurile, limbajul și comportamentul se interconectate, pentru a redefini tipare mentale și a îmbunătăți viața. 
Life coachingul se concentrează pe identificarea obiectivelor și activarea resurselor interne pentru a atinge potențialul maxim.
Hipnoza induce o stare de relaxare profundă facilitând accesul la subconștient pentru schimbări rapide.
Un terapeut format în aceste domenii devine unic prin combinația acestor metode, adaptand abordarea fiecărui client pentru rezultate optime, cu instrumente și soluții variate pentru a facilita transformări reale și durabile.', 5, 'Studii de licență, masterat Universitatea Științele Vieții " Regele Mihai I din Timișoara, inginer diplomat, Master Practician Școala Loreta Iova Timișoara, trainer acreditat Time Line Therapy Association, Tad James Company: Coach, Neuro- Programare - Lingvistică, Time Line Therapy( R), Hipnoză, consilier dezvoltare personală Centrul Athena București, master clases Eugen C. Popa - Asociația Române Hipnoză de Vindecare a Traumei;Gina Veverita, curs Huna acestea sunt în curs de certificare, Hermetism și Practici pentru un corp și o minte sănătoasă - " Școala pentru Suflet" , formare în psihopedagogie specială, cursuri post universitare Universitatea Științele Vieții " Regele Mihai I" din Timisoara;  ', '{"Master Practician NLP","Master Practician Hipnoză","Master Practician Coaching","Consilier Dezvoltare Personală"}', 200.00, NULL, NULL, '2025-05-20 08:28:21.141363+00', '2025-05-20 08:28:21.141363+00', '{"Terapie Holistică","Life Coach",Hipnoză,NLP}', 'C. Femeie, 42 ani,  medic fizioterapie-  A fost prima mea clienta  și un caz destul de complicat. Practic C. medic la Timisoara  nu reușea de 3 ani să promoveze un alt examen pentru certificarea de medic neurolog, plus că viața personală era bulversata,  divorțase, nu putea menține și gestiona o relație, părea că totul este împotriva sa. 
Este acum medic neurolog,  are cabinet medical inclusiv, în care activează atât ea cât 2 specialiști  în  tehnici specifice pentru vindecarea herniilor de disc, discopatiilor la nivel cervical; are o relație stabilă , un copil; e împlinită. 
M., barbat 25 de ani,  solist instrumental, anxietate, tulburări de somn, atacuri de panică, dependențe , paralizie facială.  În prezent e ok , are contracte, relație stabilă. 
A. femeie, 35 de ani solistă muzica populară, anxietate, Atacuri de panică  nu reușea sa cânte live pe scenă.  ', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/622d14e0-2b33-4c8b-81d5-231a707fd100-1747729699398.jpg', NULL, false),
	('072aa24d-bfc3-4b0c-93f2-1435906d8381', '{"Stima de sine","incredere de sine","cum lucram cu fricile? frica de moarte","frica de expunere","frica de esec","Ranile emotionale","care sunt si cum le abordam? Sindromul impostorului si perfectionismul","Anxietate si depresie","Cele 3 nevoi de baza ale fiecarei fiinte umane","Mediul securizant in familie si in relatii","Obiective: setare si plan de actiune","Obiective: cum sa transformi actiunile in obiceiuri si sa te tii de obiective pe termen lung","Metoda de comunicare sanatoasa","vorbeste in valorile celui de langa tine","Tipare sabotoare","Setarea limitelor sanatoase","Nivelul de merit","ce il compune si cum il crestem","Autoritati si subordonari",Dependentele,"ce sunt si cum le putem aborda","analize DISC - analiza profilului personal"}', 'Bună,

Sunt Diana, și sunt dedicată lucrului cu oamenii de mai bine de 15 ani. Sunt specializată în a ajuta oamenii să atingă creșterea personală și echilibrul emoțional folosind o abordare comportamentală cognitivă terapeutică. 

Amestecul meu unic de intuiție și metode psihologice certificate, cum ar fi abordarea Dr. John Demartini, adăugând DISC și PCM asigură rezultate eficiente. Folosesc o combinație a acestor tehnici:

Instrumentul psihometric DISC, în care sunt certificată din 2007 - licențiată să emit Thomas Personal Profile Analysis (DISC) și să lucrez cu instrumente conexe cât și sondaje și rapoarte de inteligență emoțională, că o extensie a instrumentului.
Sunt certificată pentru a oferi informații despre comportament, aptitudini, abilități de conducere, deblocarea succesului și bunăstării oamenilor.

Terapia cognitiv-comportamentală (CBT): Această abordare bazată pe dovezi ajută la identificarea și schimbarea tiparelor de gândire negative.

Metoda Dr. John Demartini: Această metodă ajută la reîncadrarea experiențelor trecute și la eliberarea bagajelor emoționale.

Am diplomă de Mental Coaching, folosită terapeutic cât și în sport.
Devii capabil să te controlezi pe tine și mintea ta, iar asta vă permite talentelor tale fizice la care ai muncit din greu, să se dezvolte și să strălucească în timpul competiției.

Teoria atașamentului: înțelegerea stilului tău de atașament poate oferi informații valoroase asupra dinamicii relațiilor tale. Vei înțelege de ce ai tendințe de a te agăța de partener, de a-l sufoca pe celălalt cu prezența ta și cu diverse cerințe sau dimpotrivă, vei afla de ce te retragi, de ce nu poți comunica și de ce îți este atât de greu să revii în conexiune.

Lucrăm și pragmatic: identificăm obiectivele tale și planificarea acțiunilor: vom lucra împreună pentru a stabili obiective SMART și a crea un plan de acțiune pentru a le atinge.

Tehnici de Mindfulness: Practicile de Mindfulness te pot ajuta să devii mai conștient de gândurile și sentimentele tale, permițându-ți să răspunzi mai degrabă decât să reacționezi, iar acest lucru vă restabili calitatea interacțiunilor tale.

Tehnici de psihologie pozitivă: Vom explora tehnici pentru a cultiva emoții pozitive și pentru a construi rezistența.

Te aștept cu deschidere să explorăm povestea ta de viață!
Sunt onorată să iau parte la evoluția ta!', 15, 'Certificare în Mental Coaching – o metodă pragmatică și științifică pentru gestionarea sănătoasă a gândurilor și emoțiilor, cu rezultate vizibile.​

Formare în coaching transformațional – abordări integrate pentru echilibru interior și reconectare cu sinele autentic.​
LinkedIn

Ateliere de psihodramă – experiențe de lucru cu sinele și cu ceilalți, facilitând introspecția și transformarea personală.​

Workshopuri de coaching emoțional – instrumente practice pentru gestionarea emoțiilor și dezvoltarea inteligenței emoționale.​

Programe de coaching pentru echipe – crearea de spații sigure pentru comunicare autentică și dezvoltare colectivă.', '{"Certificarea DISC","Curs si diploma de mental coaching","Formare specialist in domeniul resurselor umane","Model de comunicare PCM - folosit de NASA","Traininguri de leadership","Traininguri de public speaking","prezentari de mare impact"}', 300.00, NULL, NULL, '2025-05-20 09:12:26.09913+00', '2025-05-20 09:12:26.09913+00', '{"Terapie Cognitiv-Comportamentală","Life Coach"}', 'Am fost marcată de povestea unui tânăr de 18 ani care a avut 3 încercări de a se sinucide datorită tensiunilor din familie, a bătăilor, a lipsei de speranță și a faptului că el credea că nu merită să fie iubit și că nu avea parte de iubire în viața lui.

După 8 luni de lucru împreună, a ajuns la lumină, la eliberare și la recunoștință. Se simte bine și nu dorește să mai încerce așa ceva, deoarece a înțeles că este iubit, chiar de mai multe persoane și a reușit să își perceapă propria valoare.
Am fost foarte bucuroasă să îl pot ajuta.

Alte 2 cazuri care mi-au rămas în suflet, a fost însoțirea unei doamne care a trăit cu o traumă timp de 40 de ani (tatăl ei o înjunghia pe mama ei). Am reușit să descompunem evenimentul, să echilibrăm percepțiile, să ajut persoana să vadă binecuvântările evenimentului (deși pare contraintuitiv). A fost foarte încântată să simtă după câteva sesiuni că nu mai are acea apăsare emoțională și că nu mai plânge atunci când vorbește despre acel episod dureros.

Am avut si câteva cazuri în care am lucrat pe abuzuri sexuale, de asemenea cu o mare încărcătură emoțională care au putut fi echilibrate. Avem nevoie unii de alții...', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/072aa24d-bfc3-4b0c-93f2-1435906d8381-1747732345377.jpeg', NULL, false),
	('7b00956b-eafb-4d19-aed0-67dad9ab51ee', '{Anxietate,Depresie,"Tulburari alimentare","Managementul stresului"}', 'Mă numesc Mara Lica și am devenit psiholog pentru că (1) iubesc oamenii și (2) îmi doresc să ofer oamenilor un mic spațiu în care să se simtă inteleși în mod real, să se descopere și să devină ei, autentici. Rolul meu este să iți fiu alături în timp ce inflorești. Mă voi plia pe nevoile tale, cu răbdare și ințelegere, într-un spațiu lipsit de judecăți. ', 1, 'Master in Psihologie Clinica, Consiliere Psihologica si Psihoterapie, la Facultatea de Psihologie si Stiinte ale Educatiei Cluj-Napoca (incluzand Formare in Psihoterapie si Psihologie clinică, 
Asociația de Psihoterapii Cognitive și Comportamentale din România) 
Licenta in Psihologie la Facultatea de Psihologie si Stiinte ale Educatiei Cluj-Napoca 
', '{"Formare in Psihoterapie si Psihologie clinică
Asociația de Psihoterapii Cognitive și Comportamentale din România"}', 150.00, NULL, NULL, '2025-05-20 13:03:37.910391+00', '2025-05-20 13:03:37.910391+00', '{"Terapie Cognitiv-Comportamentală",Psihoterapeut}', 'Pentru mine a fost foarte revelator stagiul de practica la Institutul Oncologic din Cluj-Napoca. A fost o experienta foarte dificila, dar foarte frumoasa, in care am simtit ca sunt foarte aproape de unele dintre cele mai dificile experiente umane, de extrem de multa suferinta. Chiar si in acest loc, am intalnit persoane pline de speranta sau impacare cu viata pe care au dus-o, aflate in sectia de ingrijiri paliative. Am intalnit extraordinar de multa dragoste, atat fata de familie, cat si fata de lucruri mici, precum este bucuria unei zi cu soare. Pacientii de acolo mi-au ramas mult la suflet. ', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/7b00956b-eafb-4d19-aed0-67dad9ab51ee-1747746287547.jpg', NULL, false),
	('7f541d24-fa47-444f-9ca4-f4f7bc3f4dde', '{depresie,"anxietate socială","anxietate generalizată","atacuri de panică",fobii,traumă}', 'Salut! Sunt psiholog clinician si sunt dedicat sprijinirii celor care se confruntă cu provocări emoționale și psihologice. Ofer un spațiu sigur, confidențial și empatic, unde poți explora și înțelege mai bine dificultățile tale pentru a-ți regăsi echilibrul și liniștea interioară.

Experiența mea include evaluarea și tratarea tulburărilor emoționale, anxietății, depresiei, traumelor și fobiilor prin metode validate științific. Aplic tehnici moderne pentru a dezvolta un plan terapeutic personalizat, adaptat nevoilor tale specifice.

Înainte de a deveni psiholog clinician, am acumulat o vastă experiență in domeniul relațiilor cu clienții cât si în diagnosticarea și rezolvarea problemelor de natura tehnica, dezvoltând un stil de lucru structurat și orientat spre soluții. Această abordare analitică se îmbină perfect cu empatia și înțelegerea profundă a psihologiei umane, oferind pacienților mei strategii eficiente și bazate pe dovezi pentru îmbunătățirea sănătății mentale.

Dacă simți că ai nevoie de ajutor pentru a face față emoțiilor copleșitoare, stresului sau anxietății, sunt aici pentru a-ți oferi sprijin și îndrumare.

Programează o ședință și hai să facem împreună primul pas spre o viață mai echilibrată!', 2, 'Formarea mea profesională include:
* Facultatea de Psihologie.
* Facultatea de Stiinte Economice - Management. 
* Master "Psihologie clinica si interventie psihologica" (in curs).
* Formare în "Psihologie clinica si interventie psihologica" - Resilient Mind Center (in formare).', '{"* Membru Copsi ( Colegiul Psihologilor din Romania) - atestat în psihologie clinică.  Cod psiholog 32957.
Participare la diferite wokshopuri și cursuri de formare continuă","printre care:
* \"Bune practici în evaluarea psihologică clinică\" - Resilient Mind Center (februarie 2025)
* \"Evaluare Clinică a Adolescenților\"- Resilient Mind Center (mai 2025).
* \"Introducere in Consiliere si Psihoterapii Scurte Colaborative\" - \"Fundamente al Psihoterapiilor Eficace\" (noiembrie 2020)"}', 200.00, NULL, NULL, '2025-05-20 14:22:49.739394+00', '2025-05-20 14:22:59.804979+00', '{Psihoterapeut,"Terapie de Cuplu"}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/7f541d24-fa47-444f-9ca4-f4f7bc3f4dde-1747750969031.jpg', 'B8SCLEII', false),
	('20d55537-6f54-41d6-98a6-474174099d17', '{Psihoterapie}', 'Psihoterapeut integrativ', 3, 'Psihologie clinică
Psihoterapie integrativă
Hipnoză
Regresii', '{"Consilier de dezvoltare personală",Formator,"Terapie prin arte combinate","Psihologie și psihoterapie-în formare"}', 200.00, NULL, NULL, '2025-05-20 21:44:09.075534+00', '2025-05-20 21:44:56.056775+00', '{Psihoterapeut,Hipnoză,"Consiliere Spirituală"}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/20d55537-6f54-41d6-98a6-474174099d17-1747777448865.jpg', NULL, false),
	('6a70d9b5-4fb8-46f7-975b-5887fd4e47de', '{}', 'Sunt numerolog certificat, atestat de Ministerul Muncii și Educației din România, cu o experiență de peste 10 ani în lucrul cu oamenii prin intermediul numerologiei. Lucrez cu acest instrument pentru a oferi claritate, direcție și o mai bună înțelegere a propriului drum în viață.

Abordarea mea este empatică și structurată, ghidată de autenticitate, respect și responsabilitate. Cred că fiecare persoană are un potențial unic, iar numerologia poate scoate la lumină resursele interioare, ritmurile personale și momentele potrivite pentru acțiune.

Îmbin analiza numerologică detaliată cu intuiția și o comunicare clară, adaptând totul la realitatea fiecărui om. Fiecare sesiune este personalizată și orientată spre sprijin concret și transformare personală.

Serviciile mele includ:
- Analiză numerologică completă (data nașterii, nume)
- Compatibilitate în cuplu și relații
- Ghidare vocațională și orientare profesională
- Previziuni anuale și cicluri personale
- Suport în luarea deciziilor importante in baza la faza in care te aflii.

', 10, 'Studii econimice in Italia. Ulterior, am urmat cursuri de numerologie în Italia și România, inclusiv în cadrul Asociației Numerologilor din România. Sunt numerolog certificat, atestat de Ministerul Muncii și Ministerul Educației din România.', '{}', 300.00, NULL, NULL, '2025-05-21 08:04:57.809047+00', '2025-05-21 08:04:57.809047+00', '{Numerolog}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/6a70d9b5-4fb8-46f7-975b-5887fd4e47de-1747814697002.JPG', NULL, false),
	('cae70df8-8ff3-4f34-9d75-dae1732f24a7', '{}', '', 3, 'barolomeu, dodo
pato

Pato santo Lache', '{}', NULL, NULL, NULL, '2025-05-21 02:52:54.223922+00', '2025-05-21 03:44:34.984983+00', '{"Consiliere Spirituală"}', '', '', NULL, false),
	('8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', '{"Terapie cu adolescentii si adultii",ADHD,neurodivergenta,depresie,anxietate}', 'Bun venit, sunt Elena.
Sunt psiholog clinician și psihoterapeut formată în terapia cognitiv-comportamentală, cu un interes profund pentru tot ce ține de înțelegerea tiparelor noastre emoționale și a modului în care ne putem regăsi echilibrul interior.

În munca mea, mă regăsesc cel mai mult în două direcții terapeutice care se completează frumos:
🔸 Terapia centrată pe scheme – ne întoarcem împreună la rădăcinile din copilărie, acolo unde unele nevoi emoționale nu au fost împlinite, și începem să înțelegem cum acestea influențează tiparele tale actuale de relaționare, decizie sau reacție.
🔸 Terapia Acceptării și Angajamentului (ACT) – lucrăm pentru a crea o relație mai blândă și conștientă cu gândurile și emoțiile tale, astfel încât să poți face pași concreți spre o viață ghidată de valorile tale, nu de frici sau automatisme.

Abordarea mea este una empatică, orientată spre înțelegere profundă și schimbare durabilă. Nu cred în „reparații rapide”, ci în reconectare autentică cu sinele tău.', 2, '2017-2020: Licență - Universitatea Babeș-Bolyai - Facultatea de Psihologie și Științe ale Educației - Specializare – Psihologie
2017-2020: Departamentul de Pregătire a Personalului Didactic, Programul de Pregătire Psihopedagogică Nivelul I
2020-2022: Master – Universitatea Babeș-Bolyai – Facultatea de Psihologie și Științe ale Educației – Specializare – Psihologie Clinică, Consiliere Psihologică și Psihoterapie 
2020-2022: Departamentul de Pregătire a Personalului Didactic, Programul de Pregătire Psihopedagogică Nivelul II 
2023-2024 Supervizare in psihologie clinica (actual autonom)
2023-2025 Supervizare CBT (actual in schimbare de treapta catre autonom)
2024- in prezent formare in Terapii cognitiv comportamentale bazate pe proces (PB-CBT)

Participare Conferinta Nationala de ACT - in anul 2023, 2024, 2025
Curs Introductiv in ACT - 3-4 noiembrie 2023, Cluj Napoca
Tabara de ACT de iarna - 15-18 februarie 2024, Brasov
Invata sa inoti in FRT - curs introductiv - 22-24 martie 2024, Cluj Napoca
Act Toolkit pentru practicienti - 5-6 aprilie 2025
Mindfulness Based Stress Reduction Programme - mai-iunie 2024', '{"Atestat de libera practica in psihologie clinica - treapta autonom - evaluarea copilului si adolescentului","Atestat de libera practica in psihoterapie","specializarea psihoterapie cognitiv-comportamentala - treapta practicant in suprevizare - in proces de schimbare cu treapta de autonom"}', 150.00, NULL, NULL, '2025-05-22 15:05:00.754067+00', '2025-05-23 05:16:39.688443+00', '{Psihoterapeut,"Terapie Cognitiv-Comportamentală",Mindfulness}', 'Lucrul cu adolescenții și tinerii adulți este, pentru mine, o călătorie în care descoperim împreună nu doar ce gândesc, ci și cum trăiesc ei emoțiile în corpul lor. Sunt momente în care o strategie aparent simplă – un exercițiu de imaginație ghidată sau o tehnică cognitivă – deschide uși neașteptate în interiorul lor.

Îmi amintesc de o adolescentă care, în timpul unui exercițiu de imagerie dirijată, mi-a spus că nu se aștepta să simtă atât de intens ceea ce trăia. Mesajele pe care le imagina nu păreau construite cu mintea, ci venite dintr-un loc mai adânc, mai adevărat. Era ca și cum, pentru prima dată, își auzea răspunsul la o nevoie veche, neîmplinită – și acel răspuns venea chiar de la ea. La final, corpul ei era liniștit, iar respirația mai amplă – un semn tăcut că se întâmplase ceva important.

Sunt astfel de momente care nu pot fi planificate, dar pot fi cultivate cu grijă. Momente în care o strategie devine mai mult decât un instrument.', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/8458bab3-1fb1-4eb7-8cad-f555bc58fc8f-1747926302398.jpeg', NULL, true),
	('1f149689-c4dc-412f-8de6-9b25ee804842', '{Anxietate,Depresie,"Psihoterapie individuală","Psihoterapie de cuplu centrată pe emoții și Psihoterapie de familie și de cuplu"}', 'Pentru mine, psihoterapia reprezintă profesia pe care o practic, însă mai mult decât atât, o privesc ca fiind o artă, pe care o redescopăr cu pasiune, din nou și din nou.

Am absolvit facultatea de Psihologie din cadrul Universității Tibiscus și am urmat masterul în Psihologie Clinică din cadrul Universității de Vest Timișoara.

Am parcurs cu entuziasm și curiozitate cursurile primei formări în psihoterapie sistemică de cuplu și familie din cadrul Institutului de Terapie Familială și Practică Sistemică Areopagus. 
A doua formare finalizată este în psihoterapie individuală, de cuplu și de familie centrată pe emoții din cadrul Asociației de Psihoterapie Centrată pe Emoții pentru Cuplu și Familie. Am finalizat formarea- Evaluare și intervenție psihologică în Imunopsihologie și Psihosomatică din cadrul Intell&Psychological Profiler Academy. 
De asemenea, am participat la cursul Terapia științifică a anxietății, a burnoutului și  a depresiei în secolul 21 din cadrul Centrului de Psihoterapie Cognitrom. 
Din dorința de a evolua profesional particip în mod constant la cursuri de formare continuă, cu cea mai frumoasa aspirație de a oferi suport fiecărui om cu care interacționez, contibuind la progresul personal și la o viață mai împlinită.

Experiența de psiholog am acumulat-o, profesând o perioadă de șapte ani în două centre de servicii sociale.
Am activat ca și psiholog, cinci ani într-un centru de zi, ce avea ca scop îmbunătățirea vieții copiilor și adolescenților, care proveneau din familii aflate în dificultate socio-psiho- economică și familială, unde am lucrat cu peste 300 de copii si adolescenți.

Apoi, doi an într-un centru de tip rezidențial, care oferea suport tinerilor și adulților fără adăpost. Am cunoscut viața și dificultățile tinerilor în toată diversitatea lor, și am însoțit peste 150 de tineri și adulți sa-si regăsească valoarea și un drum cat mai funcțional în viață.
Totodată, pe o durată doi ani am fost implicată într-un proiect de consiliere adresat cu precădere tinerilor.
In decursul ultimilor 16 ani de activitate ca psiholog și psihoterapeut, am oferit cu dedicare sprijin la peste 500 de beneficiari și clienți și am acumulat o vastă experiență clinică. Am dobândit experiență de lucru cu tineri și adulți care prezentau anxietate generalizată, atacuri de panică, diferite tipuri de fobii, depresie, burnout, experiențe traumatice,  deconectare emoțională, infidelitatea unui partener și divorț.

Din anul 2020 și până în prezent activez în propriul cabinet de psihoterapie și susțin oamenii cu anxietate să se dezvolte și să își depășească dificultățile. 
 ', 16, 'Am absolvit facultatea de Psihologie din cadrul Universității Tibiscus și am urmat masterul în Psihologie Clinică din cadrul Universității de Vest Timișoara.

Am parcurs cu entuziasm și curiozitate cursurile primei formări în psihoterapie sistemică de cuplu și familie din cadrul Institutului de Terapie Familială și Practică Sistemică Areopagus. 
A doua formare finalizată este în psihoterapie individuală, de cuplu și de familie centrată pe emoții din cadrul Asociației de Psihoterapie Centrată pe Emoții pentru Cuplu și Familie. Am finalizat formarea- Evaluare și intervenție psihologică în Imunopsihologie și Psihosomatică din cadrul Intell&Psychological Profiler Academy. 
De asemenea, am participat la cursul Terapia științifică a anxietății, a burnoutului și  a depresiei în secolul 21 din cadrul Centrului de Psihoterapie Cognitrom. ', '{"Am finalizat formarea- Evaluare și intervenție psihologică în Imunopsihologie și Psihosomatică din cadrul Intell&Psychological Profiler Academy. 
De asemenea","am participat la cursul Terapia științifică a anxietății","a burnoutului și  a depresiei în secolul 21 din cadrul Centrului de Psihoterapie Cognitrom."}', NULL, NULL, NULL, '2025-05-22 12:58:43.620966+00', '2025-05-22 13:09:36.629733+00', '{Psihoterapeut,"Terapie Cognitiv-Comportamentală","Terapie de Familie","Terapie de Cuplu",NLP,Mindfulness}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/1f149689-c4dc-412f-8de6-9b25ee804842-1747919323758.jpg', NULL, false),
	('30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', '{Anxietate,"Tulburare de panica",Depresie,Traume,"Experienta cu copiii","Stima de sine"}', 'Numele meu este Melinda și sunt psihoterapeut specializat în terapia cognitiv-comportamentală. Lucrez cu oameni care își doresc să înțeleagă mai bine ce li se întâmplă în interior și care sunt pregătiți să facă schimbări reale în felul în care gândesc și se raportează la viață.

Cred că multe dintre dificultățile noastre pornesc din gânduri automate, convingeri rigide sau rănile nevindecate din trecut. De aceea, pun accent pe claritate, conștientizare și restructurare cognitivă — dar și pe blândețe și sprijin emoțional.', 2, '2023: Psihoterapie cognitiv comportamentala - Asociaţia de Psihoterapii Cognitive şi Comportamentale din România
2023: Abordarea cognitiv-comportamentală a stresului posttraumatic - Asociatia APCCR
2019-2022: Diplomă de master
Facultatea de Psihologie şi Ştiinţele Educaţiei - Universitatea Babes-Bolyai, Cluj-Napoca
2015-2018 Diplomă de licenţă
Facultatea de Psihologie şi Ştiinţele Educaţiei - Universitatea Babes-Bolyai, Cluj-Napoca', '{"Psihoterapeut cognitiv-comportamental sub supervizare","atestat de Colegiul Psihologilor din România","2025 - Psihoterapeut cognitiv-comportamental cu drept de liberă practică – treapta: autonom","atestat de Colegiul Psihologilor din România"}', NULL, NULL, NULL, '2025-05-21 08:40:42.052225+00', '2025-05-22 13:28:54.844588+00', '{Psihoterapeut,"Terapie Cognitiv-Comportamentală",Mindfulness}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/30afa3ac-3cac-4756-a1dc-3f9a2ae8d370-1747816840646.jpg', NULL, false),
	('4b6f4102-c588-406c-a091-79dd2485fb81', '{"bla bla"}', 'bla bla ', 5, 'bla bla ', '{"bla bla"}', 1.00, NULL, NULL, '2025-05-22 15:21:19.451866+00', '2025-05-22 15:21:19.451866+00', '{Dietetician}', 'bla bla ', '', NULL, false),
	('de7ba501-a94e-4f86-81b3-0afe662ae8de', '{"Life Coaching","Coaching de Business","Constelatii in Coaching","Constelatii de Familie"}', 'Sunt Life Coach si Facilitator Sistemic (facilitator Constelatii in Coaching si facilitator Constelatii de Familie). In aceste roluri lucrez din credinta ca avem toti un potential ascuns, dar disponibil si din dorinta de a-mi sustine clientii sa il aduca la suprafata si sa il manifeste in viata lor. Cred ca acesta va fi poate cel mai important mod in care voi lasa lumea un pic mai buna decat am gasit-o.

Temele cele mai recente ale clientilor mei de coaching sunt:
- reconectarea cu copilul interior
- relatia cu banii, relatia cu bucuria, relatia cu linistea
- leadership de echipa si leadership personal
- echilibrul intre munca si odihna (personal si profesional), echilibrul intre munca si timp personal, supra-responsabilizarea, burnout-ul
- relatia cu partenerul, relatia cu copii, relatiile inter-personale
- cariera profesionala, relatiile de munca, antreprenoriatul, tranzitia inspre noi roluri profesionale
- reconectarea cu corpul si intuitia, reconectarea cu inima si emotiile, reconectarea cu masculinul si cu femininul.

In prezent folosesc ca metode, in functie de nevoia, dorinta si permisiunea interioara a clientului:
- Life Coaching si Coaching de Business (spatiu pentru obiective si reflectie personala)
- Coachingul sistemic (in care creez impreuna cu clientii harti ale sistemelor interne - ale partilor/ ale "echipei interioare" sau externe - familia, locul de munca sau proiectele personale)
- Metoda constelatiilor familiale (facilitare sistemica cu focus pe familia de origine si "mostenirile" transgenerationale). In prezent folosesc aceasta metoda doar in sesiunile individuale. Voi putea facilita si sesiuni de grup dupa terminarea formarii, in 2025.
- Mentoringul (exclusiv pentru leadership de echipe).

Dincolo de metoda, atitudinile care ma insotesc in facilitare sunt curiozitatea, acceptarea si blandetea. De asemenea, acolo unde exista permisiune, am o abordare somatica, pentru a accesa si alinia toate cele 3 surse de intelepciune ale clientului - rationala (mintea), emotionala (inima) si intuitiva (corpul).', 4, 'Formarile pe care le-am urmat sau le urmez:
- Life Coaching si Coaching de Business - Scoala One2Coach. Mentori: Olga Olteanu, Adela Iepure, Cristi Nicolae, Catalina Molnar si Ana Kica Rosie.
- Coaching Constellations - Coaching Sistemic si Constelatii in Coaching, metoda dezvoltata de John Whittington. Mentori: Doru Curteanu si Oana Tanase.
- Family Constellations - Constelatii Familiale, in curs, anul 3/3. Mentor: Claus Kostka.
- Somatic Experiencing - in curs, anul 1/3, metoda dezvoltata de Peter Levine. Mentor: Liane Pinto.', '{-}', 300.00, NULL, NULL, '2025-05-22 15:12:41.656618+00', '2025-05-23 05:16:36.703854+00', '{"Life Coach"}', 'IN PREZENTA INIMII MELE
Sesiuni individuale de coaching sistemic si constelatii familiale

Acest spatiu s-a nascut din propriele mele provocari cu a ma simti in siguranta si a ma accepta asa cum sunt.

Rezervoarele noastre de intuitie si inteligenta emotionala sunt mereu pline. Sunt surse de intelepciune si energie ce par infinite in raport cu capacitatea noastra de le accesa intr-o singura viata. Sunt resurse interioare inepuizabile care nu se consuma, ci mai degraba sporesc - atunci cand le accesam sau atunci cand le impartim cu altii.

Poate si pentru ca sunt atat de pretioase, aceste rezervoare sunt pazite cu strasnicie de parti din noi pe care le-am creat atunci cand nu eram inca pregatiti sa traim anumite emotii. Ele au aparut din nevoia noastra de a ne proteja si asta fac si acum - ne protejeaza. Copilul interior, adolescentul interior, judecatorul interior, parintele interior sunt doar cateva nume pe care le dam acestor parti, atunci cand o putem face. Sunt ziduri prin care ne e greu sa trecem si uneori ne e teama chiar sa ne uitam peste ele. Sunt gardieni cu care nu avem curaj sa vorbim si in schimb ii ignoram sau ii judecam.

Ne e nevoie sa daramam zidurile si nici nu cred ca ar fi bine sa o facem. In schimb, le putem accepta ca facand parte din casa noastra interioara si apoi putem alege sa construim o fereastra si mai apoi o usa - o usa pe care o putem tine inchisa sau deschisa, dupa nevoie. O usa pe care putem intra cand e potrivit si pe care putem iesi atunci cand e prea mult si avem nevoie sa ne simtim din nou in siguranta.

Nu e nevoie sa ne luptam cu gardienii si nici nu cred ca e o lupta din care putem iesi cu adevarat victoriosi. In schimb, ii putem vedea, le putem aduce recunostinta si, cand e potrivit, am putea incepe sa vorbim cu ei. "Iti multumesc ca ai fost si ca esti aici pentru mine". "Uneori voi avea nevoie sa ma lasi sa trec, alteori voi avea nevoie de tine sa ma protejezi. Dar as vrea sa facem asta impreuna."

Putem face asta dintr-un loc in care ne acceptam asa cum suntem, in care ne simtim in siguranta sa stam cu tot ceea ce suntem si traim: tristete si bucurie, nevoie si dorinte, frici si liniste, blocaje si curaj. Doar aici putem recofigura zidurile, doar aici ne putem imprietenii cu gardienii si in timp ce ne traim tristetea, ne plangem dorul, ne infruntam fricile - ne regasim bucuria si linistea si ne conectam cu resursele noastre interioare.

Cred ca exista foarte multe astfel de locuri, sub foarte multe nume. Stiu asta pentru ca am vizitat astfel de locuri in ultimii ani. Rumi a numit acest loc "un camp", "dincolo de ideile de rau si de bine". Pentru mine el este "in prezenta inimii mele" - o fraza pe care o uit adesea, dar care nu ma uita niciodata. Poate pentru ca inca imi este greu sa cred, pe deplin, ca exista acest loc, in interiorul meu, pentru mine.

Dar acest loc exista. Inima mea stie asta. La fel si inima ta.', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/de7ba501-a94e-4f86-81b3-0afe662ae8de-1747926761111.jpg', NULL, true),
	('d3275dfe-f4df-44fc-acaa-659e92369e66', '{"Competența profesională în specialitatea „Psihoterapii cognitiv-comportamentale”"}', '  Mã străduiesc să ofer clienților servicii de cea mai bună calitate, care sunt individualizate pentru a răspunde și satisface toate nevoile acestora. Abordarea mea permite clienților să se simtă în siguranță și confortabil pe măsură ce descoperim impreunã cauza principală a barierelor în calea lor, fiind în același timp capabili să facă schimbări eficiente pe termen lung pentru a preveni reapariția ciclurilor.
Viziunea mea este că, pentru a menține un stil de viață sănătos, relații sănătoase și pentru a fi cu adevărat mulțumiți de viață, oamenii trebuie să aibă capacitatea de a recunoaște modul în care experiențele ii modelează.     ', 1, '  Licențiat în Psihologie la Facultatea de Psihologie și Științele Educatiei,specializarea Psihologie in cadrul Universitãții Spiru Haret din București. Am continuat să studiez și am urmat o formare de lungã duratã în domeniul psihoterapiei “Psihoterapii cognitiv- comportamentale”, in cadrul APSC București,avizatã de Colegiul Psihologilor din România.

            Atestat de libera practica emis de Colegiul Psihologilor din Romania,Specialitatea Psihologie Clinica. 2020.
Atestat de libera practica emis de Colegiul Psihologilor din Romania,Specialitatea Psihoterapii cognitiv-comportamentale. 2024


            Atestat de libera practicã emis de Colegiul Psihologilor din Romania,Specialitatea Psihologie aplicată în domeniul securității naționale.2024.
            Consilier pentru dezvoltare personala cod COR242324.Formator Maria Comãneanu,in cadrul Asociația Phoenix.2021.', '{"Certificat de Licentiere in utilizarea Inventarului de Personalitate Big Five","Certificat de Licentiere in utilizarea chestionarului Evaluarea Tulburarilor de Personalitate ETP duo","Atestat de libera practica emis de Colegiul Psihologilor din Romania","Specialitatea Psihologie Clinica","pe treapta de specializare: Practicant","forma de atestare:Supervizare.Din data de 13-12-2020","Atestat de libera practica emis de Colegiul Psihologilor din Romania","Specialitatea Psihoterapii Cognitiv-Comportamentale","pe treapta de specializare: Practicant","forma de atestare:Supervizare.Din data de 07-08-2024","Atestat de libera practica emis de Colegiul Psihologilor din Romania","Specialitatea Psihologie aplicată în domeniul securității naționale","pe treapta de specializare: Practicant","forma de atestare:Supervizare.Din data de 07-08-2024."}', 180.00, NULL, NULL, '2025-05-20 06:46:45.030189+00', '2025-05-23 07:18:24.339898+00', '{Psihoterapeut,"Terapie Cognitiv-Comportamentală"}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/d3275dfe-f4df-44fc-acaa-659e92369e66-1747984702890.jpg', 'MN84LFKF', false),
	('1bd491bf-3874-47d1-a4ed-0983f63a866e', '{Naturopatie,"Nutriție Holistică","Sănătate Holistică",Nutriție,Diete,"Stil de viață",Fitoterapie/Apiterapie}', 'Bine ați venit în spațiul unde știința naturii se împletește cu arta cuvântului, iar grija față de om devine ritual sacru.

Eu sunt Elisei Adam – Practician în Naturopatie și Sănătate Holistică, Consultant în Nutriție Holistică acreditat internațional de IPHM, Terapeut în Terapii Complementare (cu competențe în nutriție, diete, stil de viață, fitoterapie/apiterapie) acreditat în România de UPMCA (Uniunea Practicienilor de Medicină Complementară și Alternativă din România), dar și poet și scriitor, sculptor al emoțiilor în pagini de roman și vers.
Sub semnul înțelepciunii Naturii, mi-am asumat menirea de a-i călăuzi pe cei care interacționează cu mine spre vindecarea Trupului, Minții și Spiritului. Fie că vorbim despre nutriție personalizată, fitoterapie, apiterapie sau ajustarea stilului de viață și chiar biorezonanță, eu caut mereu să deschid porți largi către acele remedii fine pe care Dumnezeu le așează, cu răbdare, în însăși țesătura lumii. În practica mea, știința riguroasă se întâlnește cu intuiția inimii: schemele terapeutice naturiste complexe pe care le recomand se bazează pe cercetare, dar și pe acea vibrație subtilă care vede omul drept o constelație de gânduri, sentimente și energii. Lucrez pentru a regăsi armonia pierdută, a o consolida sau a o ridica spre culmi noi. Tot ceea ce descopăr și celebrez în practica holistică prinde, adesea, formă de poveste, metaforă și vers. Cărțile mele – de la ApiSapienția, biblia apiterapiei, unde sunt co-autor alături de soția mea (enciclopedie de 850 de pagini A4 despre albine, minunatele lor produse apicole, apiterapie, apidietă, pilonii principali ai stilului de viață sănătos holistic, biofotonică, cimatică (influența sunetului asupra materiei), biologie și fizică cuantice și menținerea, îmbunătățirea sau restaurarea sănătății holistice – dar, în același timp, și un ghid apiterapeutic care conține scheme apiterapeutice atât pentru medici și terapeuți, cât și pentru pacienți), până la romanele și volumele de poezii ce așteaptă lumina tiparului – sunt mărturii ale pasiunii mele pentru remediile naturale, miracolul existenței și puterea transformatoare a cuvântului.
Vă invit să pășiți cu încredere în această călătorie comună. Vom asculta împreună șoaptele plantelor, vom savura puterea terapeutică a uleiurilor esențiale, vom desluși alfabetul tainic al propriului dv. corp și ne vom bucura de fiecare pas către sănătatea deplină. Pentru că vindecarea este, înainte de toate, un act de iubire, iar iubirea, atunci când prinde glas, devine artă.

Stimate domn sau Stimată doamnă,
Oricine ați fi, trebuie să știți că boala, în general, este o enigmă care trebuie dezlegată nu doar din perspectivă strict biologică, ci și din perspectivele psiho-mentală, respectiv spirituală/duhovnicească. Sănătatea optimă este o stare de armonie completă între trup, minte și suflet. Problemele de sănătate pot fi atât de profunde, încât nu se pot ameliora sau trata oricum, fără a fi investigate și înlăturate cauzele (factorii determinanți, favorizanți și de risc, precum și terenul sau particularitățile specifice de reacție ale organismului) care stau la baza acestora. "Înainte de a vindeca pe cineva, întreabă-l dacă este pregătit să renunțe la ce l-a îmbolnăvit", spuse cândva nimeni altul decât eruditul și emeritul Hipocrate (460 – 370 î. Hr.), recunoscut ca părintele medicinei. În mod clar, Hipocrate se referea și la cauze, care pot fi extraordinar de diverse: infecții acute sau cronice insidioase cu bacterii, viruși, fungi sau paraziți, radiații ionizante și neionizante (ex.: raze gamma, raze x, electromagnetice, nucleare, etc.), metale grele și alte toxine/neurotoxine (precum xenobioticele), traume psihologice dobândite pe parcursul vieții sau congenitale (transmise copilului încă din viața intrauterină, de la mamă, tată și chiar de la strămoși, pe linie genealogică, prin memorii celulare distructive), mentalitate, obiceiuri, convingeri și credințe eronate și toxice (inclusiv superstiții) care pot schimba dinamica organismului în profunzime, alimentație dezechilibrată și nesănătoasă, dereglări biofotonice, carențe/deficiențe nutriționale, insuficiențe de organe care conduc la manifestări psihosomatice, factori de mediu nocivi/nefavorabili, dezechilibre spirituale/duhovnicești dobândite în timpul vieții sau congenitale (din naștere, transmise pe linie genealogică, de la părinți sau strămoși), poluarea, stresul psihologic și oxidativ, epigenetica, unele vicii, etc.). Orice boală are una sau mai multe cauze, iar orice cauză, odată identificată, poate fi înlăturată prin măsurile adecvate, dispărând împreună cu aceasta și efectele sale nocive, respectiv simptomele sau semnele subiective/obiective care fac parte din tabloul său clinic. Unele boli, puține la număr, sunt unicauzale, însă altele, cea mai mare parte dintre acestea, sunt multicauzale, multisistemice și multidimensionale.
"Să vrei să fii vindecat este începutul vindecării!", spuse filozoful Seneca.
Să aveți grijă de trup, minte și suflet este mai ușor doar dacă aveți voință fermă și puternică, și știți ce să faceți. Voința și informația vă dau o putere extraordinară. Dar lucrurile pe Pământ nu sunt nici pe departe ideale. În timp ce lumea în care trăim este de multe ori crudă, nedreaptă și de neînțeles, iar boala și neajunsurile vieții ne pot îndurera și umili, uneori chiar prăbuși, să nu uitați faptul că nu vi s-ar fi oferit niciodată darul vieții, care are sănătatea drept cea mai mare binecuvântare, dacă Dumnezeu nu ar fi îmbogățit cufărul Naturii cu nenumărate remedii, unele ascunse în seva rădăcinilor din pământ și în plantele de pe câmpuri și din păduri, altele colectate și elaborate de harnicele și minunatele albine – capabile să vă stimuleze activarea resurselor directe sau indirecte de echilibrare, fortifiere și vindecare ale organismului, resurse care pot conduce, în funcție de stilul dv. de viață cotidian și de gradul de înlăturare a cauzelor profunde patologice, la menținerea sau îmbunătățirea statusului sănătății dv., la care aveți dreptul.
Natura este creația lui Dumnezeu, iar remediile sale sunt unele dintre mâinile prin care El vă poate veni în ajutor. Nu în zadar Hipocrate a spus: "Fie ca hrana să-ți fie medicament (aliment funcțional) și medicamentul hrană (nutraceutic)". Foarte mulți dintre noi nu ne dăm seama de cât de importantă este sănătatea decât în momentul în care o pierdem. Vă rog să faceți 3 exerciții simple. Vă aduceți aminte cele mai frumoase clipe trăite datorită sănătății care v-a permis să le experimentați? Ați vrea să uitați cele mai urâte clipe trăite din cauza unei suferințe crunte care a implicat una sau mai multe boli? Nu ați îndrăzni să vă închipuiți cum ar fi să fiți teribil de bolnav/ă și să nu vă puteți bucura de absolut nimic, săptămâni, luni sau ani la rând? Aceste 3 exerciții vă demonstrează cât de importantă este sănătatea și de ce este atât de importantă. Însă sănătatea adevărată nu este cea "simplă, unilaterală, extrem de fragilă, aparentă", ci cea "optimă, holistică, multilaterală, robustă", care presupune, desigur, echilibrarea întregii dv. ființe, la toate nivelurile. Pentru a obține o sănătate optimă, holistică - o restabilire a echilibrului funcțional adaptativ al triadei trup-minte-suflet - printr-un model nou de gândire și o abordare diferită, complexă, trebuie să știți și să înțelegeți faptul că dv. nu vă rezumați doar la carne și oase, ci sunteți un adevărat "univers" de gânduri, cuvinte, energie, vibrație, frecvență, culoare, informație, emoții și, mai presus de toate, (biofotoni), adică lumină - toate acestea încununate de un suflet care, într-un anumit moment, se va întoarce Acasă, la Sursă, la Creator, la Dumnezeu. "Omul este, esențialmente, o ființă de lumină". Această afirmație istorică, din anii ‘70, confirmată științific, îi aparține renumitului biofizician Fritz Albert Popp, recunoscut ca tată al biofotonicii(1). Practic, cercetările științifice recunosc faptul că omul este creația lui Dumnezeu - o lumină din Lumină care trăiește și supraviețuiește cu lumină și care chiar emană lumină. Într-un mod, poate, uluitor pentru mulți dintre noi, hrana noastră este alcătuită, în afară de proteine, glucide, lipide, fibre, etc., și din biofotoni. Remediile din Natură, brute (crude, neprocesate termic), de la plante (legume, fructe, leguminoase, plante medicinale, etc.) până la minunatele produse apicole (propolis, polen, lăptișor de matcă, etc.), sunt atât un cocktail de compuși bioactivi chimici naturali (polifenoli, peptide, etc.), cât și un cocktail de biofotoni, adică lumină, cu care noi, oamenii, dar și celelalte vietăți de pe Pământ, ne hrănim ori de câte ori consumăm produse naturale crude. Biofotonii, deci lumina, joacă roluri esențiale, printre altele: facilitează comunicarea între celule, coordonează procesele metabolice și stochează și transferă energia, dar Popp (2007) și Van Wijk (2014) merg mai departe, sugerând faptul că aceștia pot juca un rol chiar în procesele deosebit de complexe ale conștienței și conștiinței noastre(2).
Menținerea sau îmbunătățirea sănătății globale, holistice, în condițiile în care omul este o ființă atât de complexă, este dependentă în totalitate de starea triadei trup – minte – suflet. La fel de importante precum biochimia, biofotonica, energetica și funcționalitatea organelor și circuitelor trupului sunt și starea și igiena minții și a sufletului, care au un răsunet în tot organismul și nu ar trebui neglijate dacă se dorește menținerea sau îmbunătățirea sănătății. Nu mai reprezintă un secret faptul că obiceiurile, convingerile și credințele greșite și toxice, inclusiv superstițiile nocive (o mentalitate eronată, în general) pot schimba în sens negativ dinamica organismului în profunzime, și că traumele psihologice dobândite pe parcursul vieții sau congenitale (transmise copilului încă din viața intrauterină, de la mamă, tată, bunici și chiar de la strămoși, pe linie genealogică, prin memorii celulare distructive), pot fi atât de puternice încât produc, printre altele, lanțuri emoționale care conduc la îmbolnăvire și la oprirea procesului de dezvoltare personală(3,4), deci o igienizare psihică, respectiv o igienizare a "mentalului colectiv celular" sunt categoric necesare. Mintea trebuie detoxifiată, hrănită cu informație benefică, armonizatoare, și echilibrată inclusiv prin optimizarea biochimiei, energeticii și biofotonicii trupului, prin detoxifiere sistemică, nutriție echilibrată, sănătoasă, restaurare și echilibrare a florei intestinale și globale, printre altele, iar mentalul colectiv celular trebuie "resetat" prin ștergerea memoriilor celulare distructive. Nu în zadar se spune: minte sănătoasă în corp sănătos. În același timp, îmbunătățirea igienei spirituale/duhovnicești, a grijii față de Suflet este esențială. Dezechilibrele spirituale/duhovnicești dobândite în timpul vieții sau congenitale (din naștere, transmise pe linie genealogică, de la părinți, bunici sau strămoși) ar trebui luate în calcul foarte serios, nesubestimate, și înlăturate prin remedii spirituale: rugăciune, post, iubire, compasiune, fapte bune necondiționate, etc. Menținerea sau îmbunătățirea igienei spirituale/duhovnicești și a sănătății globale prin apropierea de Dumnezeu, în măsura în care poate fiecare, în mod echilibrat, este necesară pentru Suflet în contextual sănătății holistice, la nivel de întreg. Practic, științific, omul este o ființă de lumină ale cărei arii multiple în forul său interior cu reflexie în exterior sunt conectate între ele. Omul este un univers complex care trebuie analizat și evaluat în întregime, în mod egal, la nivelul tuturor părților sale distincte dar unite între ele: sárx = carne (materie), sōma = trup (forma organizată a lui sárx), psyhè = suflet, sediul afectelor, pnēuma= duh/spirit (partea superioară, fină, a lui psyhè, a sufletului), noūs = minte, raţiune (partea superioară a spiritului şi cea mai fină a sufletului). Sfântul Pavel vorbea despre o "despărţitură între suflet şi spirit/duh". Cu toate că sufletul şi spiritul omului sunt din aceeaşi substanţă și că acestea nu se pot confunda, sufletul și spiritul nu sunt două entități diferite, ci una singură(5). Pe acest principiu, omul este un TOT, un EU care trebuie văzut, sondat și echilibrat în ansamblu pentru menținerea sau îmbunătățirea stării sale de sănătate. În condiții atât de complexe, în care omul este suma unui cumul impresionant de factori, constant și variabile, motivația de a aborda orice problemă de sănătate într-o manieră profesionistă, responsabilă și holistică (integrală), este justificată și chiar obligatorie. În baza acestui fundament, vă invit să facem împreună o anchetă de mare amplitudine realizată prin intermediul unui set impresionant și complex de întrebări foarte bine gândite, corelaționate, care sondează în întregimea potrivită, neepuizând, cele mai importante aspecte ale stării dv. de sănătate globale, aspecte precum: indici metabolici, tendințe ale organismului, factori determinanți, favorizanți și de risc, particularități specifice de reacție ale organismului, status psiho-mental, funcții organice, igienă spirituală/duhovnicească, erori majore de stil de viață, greșeli de alimentație, diverse particularități evolutive, corelația și conectarea dintre diferite componente ale stării de sănătate versus boală printre care și: activitate fizică-baie de natură (soare, lumină, pământ, copaci, etc.)-hidratare-somn, nutriție-epigenetică-detoxifiere-longevitate, intestine-floră intestinală-digestie-sistem imunitar, infecții-toxicitate-carențe-inflamație, poluare-dereglări biofotonice-insuficiențe de organe-psihosomatizare, stres psihologic și oxidativ-mitocondrii-îmbătrânire prematură-metabolism dereglat, memorii celulare distructive-mentalitate eronată-lanțuri emoționale-vindecare emoțională, printre altele, în oglindire directă cu istoricul medical (anamneză), simptomele/semnele subiective și obiective din prezent, diagnosticele clinice din prezent și elaborarea strategiei terapeutice optime, complexe, holistice, personalizate, adaptate fiecărei persoane în parte. Cui se adresează această anchetă? Tuturor persoanelor sănătoase și bolnave deopotrivă care doresc o evaluare holistică, profundă și amănunțită a stării de sănătate, precum și indicații terapeutice personalizate, bazate pe cercetări științifice valide, pentru menținerea sau îmbunătățirea sănătății în mod optim și sustenabil (durabil), multilateral, multidimensional, multisistemic.
© Elisei Adam, toate drepturile sunt rezervate. Textul este înregistrat cu dovadă i-DEPOT, la oficiul BOIP (Benelux Office for Intellectual Property), drept urmare nu poate fi folosit în practica terapeutică decât de către autorul acestuia. Orice folosire frauduloasă poate fi sancționată conform legii dreptului de autor. 
Bibliografie: 1(Fritz-Albert Popp, L.V. Beloussov, Integrative Biophysics: Biophotonics, Springer, 2010), 2(Henk Kieft, Light in plant and animal, the practical use of bio-photons, 2018, gaiacampus.com), 3(Myriam Brousse, Valerie Peronnet, Corpul nu uită. Philobia, 2019; Myriam Brousse, Corpul ne vorbește, Philobia, 2021), 4(Bruce Lipton, The Biology of Belief. Hay House Inc., 2016), 5("Omul este trup şi suflet. ADN-ul, codul vieţii biologice", articol semnat de Eugen Gantolea, crestinortodox.ro).

Cu respect,
Terapeut Holistic Elisei Adam
Link-uri către profilele mele:
1. IPHM EXECUTIVE PRACTITIONER: https://www.iphm.co.uk/directory/find-a-professional-practitioner/adam-elisei/
2. De facebook, pagină publică de terapeut cu peste 52.000 de urmăritori: https://www.facebook.com/TerapeutEliseiAdam.IPHM
3. De ROmedic, profil cu cele mai multe răspunsuri apreciate printr-un like de pe întreg forumul, dintre toți userii, medicii, terapeuții, etc., peste 11.000 de like-uri: https://www.romedic.ro/forum.php?user=25588', 10, 'Practician în Sănătate Holistică acreditat internațional de IPHM, CMA și NCCAP.
Consultant în Nutriție Holistică acreditat internațional de IPHM, CMA și NCCAP.
Practician în Naturopatie acreditat internațional de IPHM, CMA și NCCAP.
Terapeut în Terapii Complementare specializat în Fitoterapie/Apiterapie acreditat în România UPMCA (Uniunea Practicienilor de Medicina Complementara și Alternativă).
Tehnician Nutriționist (Nutriție, Diete, Stil de Viață) acreditat în România de UPMCA (Uniunea Practicienilor de Medicina Complementara și Alternativă).
Teologie Ortodoxă Didactică, Facultatea de Teologie Ortodoxă Justinian Patriarhul, Universitatea din București.
Modulul Psihopedagogic, nivel I, Departamentul de Formare a Profesorilor, Facultatea de Psihologie și Științele Educației, Universitatea din București.
Geografia Mediului, Facultatea de Geografie, Universitatea din București.
Networking Essentials, Cisco Networking Academy, InfoAcademy București.
IoT (Internet of Things), Cisco Networking Academy, InfoAcademy București.
Spaniolă, Institutul European de Cursuri prin Corespondență (Filiala E.S.C.C. (The European School for Correspondence Courses)), EUROCOR.
Engleză, B2 - Nivel Post-Intermediar (Vantage), vorbitor INDEPENDENT, Facultatea de Limbi și Literaturi Străine, Departamentul de Limbi Moderne, Universitatea din București.
Liceul Teoretic Traian Lalescu, Real, Matematică - Informatică. ', '{Naturopatie,"Nutriție Holistică","Sănătate Holistică",Nutriție,Diete,"Stil de viață",Fitoterapie/Apiterapie}', NULL, NULL, NULL, '2025-05-22 13:30:34.930292+00', '2025-05-23 12:13:59.900919+00', '{"Terapie Holistică",Nutriție,"Consiliere Spirituală"}', '', 'https://rxcbvobdkjxlialvodik.supabase.co/storage/v1/object/public/therapist_profiles/1bd491bf-3874-47d1-a4ed-0983f63a866e-1747920559712.jpg', 'D08XBRG9', false);


--
-- Data for Name: appointments; Type: TABLE DATA; Schema: public; Owner: postgres
--



--
-- Data for Name: calendly_integrations; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO "public"."calendly_integrations" ("id", "user_id", "access_token", "refresh_token", "token_type", "expires_at", "scope", "calendly_user_uri", "calendly_organization_uri", "created_at", "updated_at", "calendly_scheduling_url", "calendly_user_name") VALUES
	('8ab8201f-cdf9-49bc-84b9-95831487a41b', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', 'eyJraWQiOiIxY2UxZTEzNjE3ZGNmNzY2YjNjZWJjY2Y4ZGM1YmFmYThhNjVlNjg0MDIzZjdjMzJiZTgzNDliMjM4MDEzNWI0IiwidHlwIjoiSldUIiwiYWxnIjoiRVMyNTYifQ.eyJpc3MiOiJodHRwczovL2F1dGguY2FsZW5kbHkuY29tIiwiaWF0IjoxNzQ2OTg2ODM1LCJqdGkiOiJkM2Y2YjY1Zi04NzA3LTQxMjAtOTk1NC1iODYxODdhNDMzY2IiLCJ1c2VyX3V1aWQiOiI1Mjk0N2U2MS01NmI3LTRjM2EtYjZlZC03OWUwMTc3Yzk0MTAiLCJhcHBfdWlkIjoiV3RZUVYtS1lBV2tmc0NNU1VUWjdqbWxjSEJNWDZSQzRfOWh5UXdaZUpRWSIsImV4cCI6MTc0Njk5NDAzNX0.A_JX8r8scP7oTiWrQcxOpYAmeupkv_CJ9Bg6hR0HV4MDecYRFaDdngyV1OLDkhFSQpJvGlVrVDVPPtG8qSrWJw', 'WoYmEg94PoIToSm2rf4JsK9Eq2F65Ypk4JEp5wx2ZCU', 'Bearer', '2025-05-11 20:07:16.182+00', 'default', 'https://api.calendly.com/users/52947e61-56b7-4c3a-b6ed-79e0177c9410', 'https://api.calendly.com/organizations/dac56ed1-844e-41b9-8dde-46c5ac73266a', '2025-05-11 18:07:16.290292+00', '2025-05-11 18:07:16.182+00', 'https://calendly.com/lao-water7', 'Lao Water'),
	('3eee76ca-cae9-47f6-84b5-d53a6d5c3040', '072aa24d-bfc3-4b0c-93f2-1435906d8381', 'eyJraWQiOiIxY2UxZTEzNjE3ZGNmNzY2YjNjZWJjY2Y4ZGM1YmFmYThhNjVlNjg0MDIzZjdjMzJiZTgzNDliMjM4MDEzNWI0IiwidHlwIjoiSldUIiwiYWxnIjoiRVMyNTYifQ.eyJpc3MiOiJodHRwczovL2F1dGguY2FsZW5kbHkuY29tIiwiaWF0IjoxNzQ3NzM5MzIxLCJqdGkiOiJlMzI4YzVlYS0yZTRiLTQzN2QtODcyNy00NDMwZTA0MTMzMDEiLCJ1c2VyX3V1aWQiOiJmOTU3ZGFiZS04NDJmLTQ4MDYtOGM5ZS00MGZiZDM1YzRiOTYiLCJhcHBfdWlkIjoiV3RZUVYtS1lBV2tmc0NNU1VUWjdqbWxjSEJNWDZSQzRfOWh5UXdaZUpRWSIsImV4cCI6MTc0Nzc0NjUyMX0.ywd21Jk3Wu3A5s9EeOBcdV5Z7xzGscRJkGnufe2jPE8qQXEN8edB-M5CbgupZ-0Rd6RvAA-QK0luv5hlRvohAw', 'pAANay1ueK04l-27HkaBfuNdaB8xK60V4nskcdubEzM', 'Bearer', '2025-05-20 13:08:42.523+00', 'default', 'https://api.calendly.com/users/f957dabe-842f-4806-8c9e-40fbd35c4b96', 'https://api.calendly.com/organizations/6d7d8dd8-69a3-4e4b-b8dd-33322f856228', '2025-05-20 11:08:42.611727+00', '2025-05-20 11:08:42.523+00', 'https://calendly.com/dianasimutm', 'Diana Olivia Simu'),
	('8bef2bb3-d8cd-4101-ae00-3b1745874d88', '3a317800-976d-4277-a491-27d7962bb16b', 'eyJraWQiOiIxY2UxZTEzNjE3ZGNmNzY2YjNjZWJjY2Y4ZGM1YmFmYThhNjVlNjg0MDIzZjdjMzJiZTgzNDliMjM4MDEzNWI0IiwidHlwIjoiSldUIiwiYWxnIjoiRVMyNTYifQ.eyJpc3MiOiJodHRwczovL2F1dGguY2FsZW5kbHkuY29tIiwiaWF0IjoxNzQ3ODQxMzIxLCJqdGkiOiI5MjhlZTY1ZC0wZmNmLTRiNWEtYWMzZS01OTU2MWNjODA2NzEiLCJ1c2VyX3V1aWQiOiJCQ0REN0U2UDZBWEhOWUFQIiwiYXBwX3VpZCI6Ild0WVFWLUtZQVdrZnNDTVNVVFo3am1sY0hCTVg2UkM0XzloeVF3WmVKUVkiLCJleHAiOjE3NDc4NDg1MjF9.CVHxGrBmOJiUkvgu_I4DS1TNlE3wXJYy5iCDlxY46Cne7ZmI7SVeW9tNifbjASE2LEmmt49X5bERRCgtIW3TKw', 'EHWSl1YQWNPmIzU2VpdWu8iS9FQAd6NolnVI5z9vLVE', 'Bearer', '2025-05-21 17:28:41.548+00', 'default', 'https://api.calendly.com/users/BCDD7E6P6AXHNYAP', 'https://api.calendly.com/organizations/AFHEOMY5WRRIWNIO', '2025-05-21 15:28:41.627897+00', '2025-05-21 15:28:41.548+00', 'https://calendly.com/suciaghi', 'Alexandru Suciaghi'),
	('e33edeb4-62d0-4645-ab81-333e922ef971', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', 'eyJraWQiOiIxY2UxZTEzNjE3ZGNmNzY2YjNjZWJjY2Y4ZGM1YmFmYThhNjVlNjg0MDIzZjdjMzJiZTgzNDliMjM4MDEzNWI0IiwidHlwIjoiSldUIiwiYWxnIjoiRVMyNTYifQ.eyJpc3MiOiJodHRwczovL2F1dGguY2FsZW5kbHkuY29tIiwiaWF0IjoxNzQ3OTI3MDI4LCJqdGkiOiJlMjg2ZmZmZC01NGIzLTRlNWItOTA3My1mZTkzNzRmYjQ2MzUiLCJ1c2VyX3V1aWQiOiI3NDE4OWI2MC0wZDM2LTRlMTctOWUzNS1jZGMzMDU3ZDhiOWQiLCJhcHBfdWlkIjoiV3RZUVYtS1lBV2tmc0NNU1VUWjdqbWxjSEJNWDZSQzRfOWh5UXdaZUpRWSIsImV4cCI6MTc0NzkzNDIyOH0.iWMVzsMGYmIqb-gW2RzHpYvF7PsYWgQKKPRUgoBoJyihPs4JO8EIZ-VN61MMh6KYPSrWLPp98mnkOvaQdEWx0g', 'Uppxkyiuqgtzt1TNT8C8jD587uriQNttvIZ43QkRZ4A', 'Bearer', '2025-05-22 17:17:09.129+00', 'default', 'https://api.calendly.com/users/74189b60-0d36-4e17-9e35-cdc3057d8b9d', 'https://api.calendly.com/organizations/bb81a4e6-fd48-4a1c-bfc8-1d3c1c4e3ff0', '2025-05-22 15:17:09.217642+00', '2025-05-22 15:17:09.129+00', 'https://calendly.com/sandu_elena1998', 'Sandu Elena'),
	('9eff3058-6a29-43c7-b704-24161374616b', 'd3275dfe-f4df-44fc-acaa-659e92369e66', 'eyJraWQiOiIxY2UxZTEzNjE3ZGNmNzY2YjNjZWJjY2Y4ZGM1YmFmYThhNjVlNjg0MDIzZjdjMzJiZTgzNDliMjM4MDEzNWI0IiwidHlwIjoiSldUIiwiYWxnIjoiRVMyNTYifQ.eyJpc3MiOiJodHRwczovL2F1dGguY2FsZW5kbHkuY29tIiwiaWF0IjoxNzQ3OTg0NDcxLCJqdGkiOiI2NzRmZTdmNi1iZDJjLTQxNmItYjRkNS0zYzFhOThmOTZmOTgiLCJ1c2VyX3V1aWQiOiJjNTcxMmJjYS1jNWViLTRhMzktYTE4Yi02ODM5NTRlNDBiODgiLCJhcHBfdWlkIjoiV3RZUVYtS1lBV2tmc0NNU1VUWjdqbWxjSEJNWDZSQzRfOWh5UXdaZUpRWSIsImV4cCI6MTc0Nzk5MTY3MX0.Yd7z0JkUGxdhKyKYEFPQ2Q1GntLrakqWD-1SICykQRpQLFwPJ37bEtGkBNwOZreTZneSjmAfV_vWtleU4DAJag', 'PQo6UIL4Ow445I48-PKB8kOk1tE5R5obedY2OgZoH50', 'Bearer', '2025-05-23 09:14:31.609+00', 'default', 'https://api.calendly.com/users/c5712bca-c5eb-4a39-a18b-683954e40b88', 'https://api.calendly.com/organizations/eb9e5256-0a6a-40ef-bd01-26076b2c4a00', '2025-05-23 07:14:31.695958+00', '2025-05-23 07:14:31.609+00', 'https://calendly.com/danutjilavu', 'Danut Jilavu'),
	('abfcce33-3032-4646-86ff-d267036f8fcf', '1bd491bf-3874-47d1-a4ed-0983f63a866e', 'eyJraWQiOiIxY2UxZTEzNjE3ZGNmNzY2YjNjZWJjY2Y4ZGM1YmFmYThhNjVlNjg0MDIzZjdjMzJiZTgzNDliMjM4MDEzNWI0IiwidHlwIjoiSldUIiwiYWxnIjoiRVMyNTYifQ.eyJpc3MiOiJodHRwczovL2F1dGguY2FsZW5kbHkuY29tIiwiaWF0IjoxNzQ3OTkyNTk2LCJqdGkiOiIzZTAzMjc0Zi1mNTExLTRhMzctODFkMS0wN2I5MmE4YWZhODIiLCJ1c2VyX3V1aWQiOiJlMmMwMmU1NC01NGZlLTRmMDUtYmZlOC00MDExODQ1Y2M5YjQiLCJhcHBfdWlkIjoiV3RZUVYtS1lBV2tmc0NNU1VUWjdqbWxjSEJNWDZSQzRfOWh5UXdaZUpRWSIsImV4cCI6MTc0Nzk5OTc5Nn0.pneZ01uQ4QMRj4Nm0y2X-1JW7Ylfomjtq51vRWBq4O5pOKtPTNk2VIQNcPAlZaW2nU6QkBgeZXR9JCpIq2lcXA', 'C3ZE0vieSMJzbfXQjTbpi2TzJ77DQCiDxpjC3cYwMCs', 'Bearer', '2025-05-23 11:29:57.269+00', 'default', 'https://api.calendly.com/users/e2c02e54-54fe-4f05-bfe8-4011845cc9b4', 'https://api.calendly.com/organizations/323b5a69-302b-437c-9a48-573b7348eb04', '2025-05-23 09:29:57.354558+00', '2025-05-23 09:29:57.269+00', 'https://calendly.com/terapeutholistic-eliseiadam', 'Elisei Adam');


--
-- Data for Name: client_preferences; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO "public"."client_preferences" ("id", "client_id", "therapy_type", "therapist_gender", "therapist_age_group", "other_preferences", "created_at", "updated_at", "progress", "email", "phone", "confidential_mode") VALUES
	('b69ad9f3-e4ba-4d59-907a-6a839c1e6b98', NULL, 'individuala', 'masculin', 'peste_50', '', '2025-04-28 06:07:42.068196+00', '2025-04-28 06:07:42.068196+00', 100, NULL, NULL, NULL),
	('bfad9ed6-86a3-4443-8eff-26c48f020980', NULL, 'individuala', 'masculin', '20-30', 'sa fie buna fata', '2025-04-28 06:25:56.01044+00', '2025-04-28 06:25:56.01044+00', 100, NULL, NULL, NULL),
	('0d807cef-b598-4f02-8ced-34ebf1b6aa76', NULL, 'cuplu', 'feminin', 'nu_conteaza', 'sa fie una buna, maxim hai 35 ani, da buna neaparat', '2025-04-28 14:52:25.948462+00', '2025-04-28 14:52:25.948462+00', 100, NULL, NULL, NULL),
	('3d936589-b813-4ed2-9997-9f965976bfc6', NULL, 'cuplu', 'nu_conteaza', '', '', '2025-04-29 15:44:07.955053+00', '2025-04-29 15:44:07.955053+00', 100, NULL, NULL, NULL),
	('2f0485ea-b886-41b8-8f6f-27c68e35da1b', NULL, 'cuplu', 'nu_conteaza', '30-50', 'Sa fie ieftin', '2025-05-01 16:12:26.639909+00', '2025-05-01 16:12:26.639909+00', 100, NULL, NULL, NULL),
	('34deb751-fef0-4f00-9ee0-64cb582723eb', NULL, '', '', '30-50', '', '2025-05-02 03:28:15.297387+00', '2025-05-02 03:28:15.297387+00', 100, NULL, NULL, NULL),
	('555edbc8-dd0d-4d1a-94a8-2a403ae98e6d', NULL, '', '', '30-50', '', '2025-05-02 04:00:26.6574+00', '2025-05-02 04:00:26.6574+00', 100, 'sosolino@mail.com', '077546453', NULL),
	('161fded5-b963-454c-95d8-1a8e1a20c225', NULL, 'individuala', 'feminin', '', '', '2025-05-06 07:18:20.469113+00', '2025-05-06 07:18:20.469113+00', 100, '', '', 'false'),
	('4bd580d5-d8f9-4e71-a4cd-a01fa4ddd4dc', NULL, 'individuala', 'feminin', 'peste_50', '', '2025-05-06 07:18:41.948805+00', '2025-05-06 07:18:41.948805+00', 100, '', '', 'false'),
	('08d855c4-f10d-478a-ac61-2b01a898190c', NULL, 'individuala', 'feminin', '30-50', '', '2025-05-06 08:39:10.524644+00', '2025-05-06 08:39:10.524644+00', 100, '', '', 'false'),
	('61d25dca-254b-403a-bef9-b7a92f043e5d', NULL, '', '', '', '', '2025-05-07 03:02:52.755535+00', '2025-05-07 03:02:52.755535+00', 100, '', '', 'false'),
	('8bdafce5-ef6b-443e-bc42-a6066de630c3', NULL, '', '', '', '', '2025-05-07 03:10:11.610695+00', '2025-05-07 03:10:11.610695+00', 100, '', '', 'false'),
	('24e55bb9-bf87-4f27-8974-314ed1893005', NULL, '', '', '', '', '2025-05-07 03:13:02.151273+00', '2025-05-07 03:13:02.151273+00', 100, '', '', 'false'),
	('57ee0b9b-1819-4ebd-8d38-1018fe65957a', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '', '', '', '', '2025-05-09 04:52:27.549186+00', '2025-05-09 04:52:27.549186+00', 100, 'sory.loby@gmail.com', '', 'false'),
	('d3ee93fd-8f29-4268-83d0-b4dce93e277b', 'df1d2f97-8f64-4160-a909-9039e6619ae3', 'cuplu', 'feminin', '20-30', '', '2025-05-13 08:13:56.241184+00', '2025-05-13 08:13:56.241184+00', 100, 'psihologandreeadianaion@gmail.com', '', 'true'),
	('b5c91a53-74ed-410b-8595-e8f30503c937', '07a95865-754b-4fed-ae0a-d4b69c486190', 'individuala', 'feminin', 'nu_conteaza', '', '2025-05-15 13:03:05.999421+00', '2025-05-15 13:03:05.999421+00', 100, 'carmendadu@gmail.com', '', 'false'),
	('c7fcd50f-209a-4a76-9d26-386fb8d74d01', '512c3b3b-0fa0-4659-8c0e-daccd911baa6', 'individuala', 'feminin', '30-50', '', '2025-05-16 09:12:11.563251+00', '2025-05-16 09:12:11.563251+00', 100, 'petruspop.catalina@gmail.com', '', 'false'),
	('f0a343b0-0e04-4a7c-82b2-3bf3faaa6f23', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', 'individuala', 'feminin', '20-30', '', '2025-05-17 10:55:40.004228+00', '2025-05-17 10:55:40.004228+00', 100, 'romanica.denisa@gmail.com', '', 'false'),
	('7a59a181-b21a-479d-8cbe-97728b78eeef', 'ab84c874-6fed-45be-9e1d-28da0a041149', 'individuala', 'nu_conteaza', 'nu_conteaza', 'Certificat psyhoterapie integrativa ARPI', '2025-05-19 07:55:19.492311+00', '2025-05-19 07:55:19.492311+00', 100, 'elenadaniele_popa@yahoo.com', '+201027444400', 'true'),
	('544fb8b0-f4bc-4b3d-869f-7a563feaf649', 'c727ce88-386f-49e6-88c9-df7115e793e5', '', '', '', '', '2025-05-19 08:08:24.346931+00', '2025-05-19 08:08:24.346931+00', 100, 'gianinacornea@yahoo.com', '', 'false'),
	('b88ad163-cd77-4ee5-9abd-0f49feae1010', 'd3275dfe-f4df-44fc-acaa-659e92369e66', 'individuala', 'nu_conteaza', 'nu_conteaza', 'Nu', '2025-05-20 06:53:42.516896+00', '2025-05-20 06:53:42.516896+00', 100, 'danutjilavu@yahoo.com', '0725626407', 'true'),
	('a4e9c11f-4dd9-4bf3-8ceb-5388cc6d4f1b', 'd3275dfe-f4df-44fc-acaa-659e92369e66', 'individuala', 'nu_conteaza', 'nu_conteaza', '', '2025-05-20 12:01:54.708281+00', '2025-05-20 12:01:54.708281+00', 100, 'danutjilavu@yahoo.com', '', 'false'),
	('8c7db62f-9cc5-4433-9ce3-b0feb02f7bed', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', 'individuala', 'masculin', '30-50', 'Constelatii familiale', '2025-05-23 11:42:35.311158+00', '2025-05-23 11:42:35.311158+00', 100, 'dan.magirescu@innercoach.ro', '0753098880', 'true');


--
-- Data for Name: news_feed_posts; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO "public"."news_feed_posts" ("id", "content", "posted_at", "created_at") VALUES
	('9ac71b1f-7ad8-4e04-90ca-08148f5cba61', 'Platforma Terapie Acasa este LIVE! Astăzi lansăm oficial locul unde găsești sprijin profesional pentru sănătatea ta mentală. Bine ai venit în comunitatea noastră!', '2025-04-28 07:00:00+00', '2025-05-21 05:06:30.067296+00'),
	('ea5677aa-f1e9-43de-9433-102c2f4b717d', 'Am început construcția arhitecturii client-terapeut! Algoritmul nostru unic de potrivire va revoluționa modul în care găsești terapeutul potrivit pentru nevoile tale specifice. #InovațieÎnTerapie', '2025-05-01 09:30:00+00', '2025-05-21 05:06:30.067296+00'),
	('0ac3424b-082a-4d84-b53b-c4adbaf4f1a9', 'Cercetăm și antrenăm continuu modelele noastre AI de ultimă generație pentru a înțelege arhetipurile specifice terapeuților. Construim prima linie gratuită de "apărare" pentru oricine dorește să exploreze sănătatea mentală. #InteligențăArtificială #SănătateMentală', '2025-05-05 06:15:00+00', '2025-05-21 05:06:30.067296+00'),
	('3eeb7115-fd65-48d2-9a06-a9929f6283a7', 'Este uimitor cum, atunci când vorbești cu un model de limbaj avansat, mintea renunță automat la toate temerile și prejudecățile... și devine dintr-o dată - Liberă. Ce ar fi dacă am putea aduce acest sistem familiilor și prietenilor noștri? Curând va fi posibil! #LibertateaMintii', '2025-05-08 12:45:00+00', '2025-05-21 05:06:30.067296+00'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', 'Astăzi deschidem porțile pentru terapeuți! Dacă ești un profesionist în sănătate mentală, te invităm să te alături platformei noastre revoluționare. Împreună putem ajuta mai mulți oameni decât oricând. Înregistrează-te acum! #TerapieAccesibilă', '2025-05-10 08:00:00+00', '2025-05-21 05:06:30.067296+00'),
	('eca02431-c053-4bb5-9066-195ea582a620', 'Modelele noastre AI sunt acum disponibile pentru utilizare publică! Am creat și abonamente gratuite pentru a asigura accesul tuturor la suport de bază pentru sănătatea mentală. Primul pas spre vindecare începe aici. #AccesGratuitLaTerapie', '2025-05-13 11:20:00+00', '2025-05-21 05:06:30.067296+00'),
	('de8cbc91-854c-4c7f-a734-8427c82ed3a2', 'Noutate extraordinară: MEMORIE! Când antrenezi un model personalizat de limbaj, încerci să găsești funcția matematică perfectă astfel încât comportamentul multidimensional să se asemene cu cel al unei "Minți" reale. Memoria complică întotdeauna lucrurile - dar astăzi am integrat cu succes Memoria în modelele noastre AI! Bucură-te acum de asistența AI cu Memorie pe Termen Scurt! #ProgresTehnologic', '2025-05-18 07:30:00+00', '2025-05-21 05:06:30.067296+00'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', 'În curând deschidem porțile pentru clienți! Ești pregătit? Asigură-te că profilul tău este complet și clar pentru ca Algoritmul nostru să funcționeze optim și să te conecteze cu terapeutul perfect pentru tine. #PregătirePentruLansare', '2025-05-20 13:00:00+00', '2025-05-21 05:06:30.067296+00'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', 'Suntem copleșiți de interesul masiv arătat de terapeuți și psihologi! Peste 50 de profesioniști s-au alăturat platformei în prima săptămână. Pregătim lansarea pentru public - din experiența beta, algoritmul nostru de potrivire a atins o precizie de 92%! #RezultateExcepționale', '2025-05-21 06:00:00+00', '2025-05-21 05:06:30.067296+00');


--
-- Data for Name: news_feed_comments; Type: TABLE DATA; Schema: public; Owner: postgres
--



--
-- Data for Name: news_feed_likes; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO "public"."news_feed_likes" ("post_id", "user_id", "created_at", "like_id") VALUES
	('9ac71b1f-7ad8-4e04-90ca-08148f5cba61', NULL, '2025-05-21 05:07:16.14829+00', '15d24c37-8842-431b-8e68-f89c46f67a12'),
	('9ac71b1f-7ad8-4e04-90ca-08148f5cba61', NULL, '2025-05-21 05:08:52.247158+00', '1b4c6a7b-d068-4a18-ba41-273d60478137'),
	('ea5677aa-f1e9-43de-9433-102c2f4b717d', NULL, '2025-05-21 05:08:52.247158+00', 'baeccc8d-79f6-409b-9a6b-8d7e754c50bf'),
	('0ac3424b-082a-4d84-b53b-c4adbaf4f1a9', NULL, '2025-05-21 05:08:52.247158+00', 'c8c59201-3569-4050-a8a5-633f51594b8b'),
	('3eeb7115-fd65-48d2-9a06-a9929f6283a7', NULL, '2025-05-21 05:08:52.247158+00', '7a516017-4df5-4ed6-9e9e-55ce7059b983'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:08:52.247158+00', 'dd1a36f2-8ccd-440c-9759-c607d14bd1ef'),
	('eca02431-c053-4bb5-9066-195ea582a620', NULL, '2025-05-21 05:08:52.247158+00', '4aae004c-a73e-47f9-95c0-067d14e41694'),
	('de8cbc91-854c-4c7f-a734-8427c82ed3a2', NULL, '2025-05-21 05:08:52.247158+00', 'cb2efb04-af9e-4a1e-87a9-0c86f02c2d8b'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:08:52.247158+00', 'ad9c43c7-d8c9-4cc9-b480-ab1c3a91c729'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:08:52.247158+00', 'de357b41-e40c-4cc3-9ebe-5267f3db3e99'),
	('9ac71b1f-7ad8-4e04-90ca-08148f5cba61', NULL, '2025-05-21 05:08:53.001578+00', 'd2e6b518-f64c-4bcf-993a-afc972fa9762'),
	('ea5677aa-f1e9-43de-9433-102c2f4b717d', NULL, '2025-05-21 05:08:53.001578+00', 'a7fac8f3-11bf-49a0-947a-3e6656e39f33'),
	('0ac3424b-082a-4d84-b53b-c4adbaf4f1a9', NULL, '2025-05-21 05:08:53.001578+00', '9d45764b-0a58-4505-a580-f7832c79c161'),
	('3eeb7115-fd65-48d2-9a06-a9929f6283a7', NULL, '2025-05-21 05:08:53.001578+00', 'a0fab5e2-f524-4680-a5f0-d497a55d63ae'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:08:53.001578+00', '2ace6edc-292a-4a72-876d-e22630f41145'),
	('eca02431-c053-4bb5-9066-195ea582a620', NULL, '2025-05-21 05:08:53.001578+00', '5cd7852b-c0bc-43b9-a36c-1cd874deba18'),
	('de8cbc91-854c-4c7f-a734-8427c82ed3a2', NULL, '2025-05-21 05:08:53.001578+00', '94ff8fe7-7a25-4559-b4e5-bc7aa29ccdcb'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:08:53.001578+00', '5563075e-36ef-4942-ad34-e2c7c96e94ef'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:08:53.001578+00', '181eabe7-d9f8-42eb-bb1c-c01f7a3f684e'),
	('9ac71b1f-7ad8-4e04-90ca-08148f5cba61', NULL, '2025-05-21 05:08:53.521159+00', 'e9954192-84f2-44f1-8080-9dbe236f1d8c'),
	('ea5677aa-f1e9-43de-9433-102c2f4b717d', NULL, '2025-05-21 05:08:53.521159+00', '0ff139d4-2fab-4203-9fcf-805bc44ab059'),
	('0ac3424b-082a-4d84-b53b-c4adbaf4f1a9', NULL, '2025-05-21 05:08:53.521159+00', 'c98ec591-adea-4309-8534-79fde11e2988'),
	('3eeb7115-fd65-48d2-9a06-a9929f6283a7', NULL, '2025-05-21 05:08:53.521159+00', 'e57716cb-f476-4e30-96b6-e925a1b53bc1'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:08:53.521159+00', '66d1bcc2-24c5-4b38-942f-b70cbed12dea'),
	('eca02431-c053-4bb5-9066-195ea582a620', NULL, '2025-05-21 05:08:53.521159+00', '2ea54368-7f2b-4528-ba66-937bbb87ccfc'),
	('de8cbc91-854c-4c7f-a734-8427c82ed3a2', NULL, '2025-05-21 05:08:53.521159+00', 'dd4671f9-c5a1-4c52-b870-ca41c400e772'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:08:53.521159+00', 'af35ea41-00b2-4e4b-9642-ccfae4b783dc'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:08:53.521159+00', '9f304135-de9a-4396-b9ca-9f8f61d10738'),
	('9ac71b1f-7ad8-4e04-90ca-08148f5cba61', NULL, '2025-05-21 05:08:54.116176+00', '18734b45-6798-4579-869a-585c90766742'),
	('ea5677aa-f1e9-43de-9433-102c2f4b717d', NULL, '2025-05-21 05:08:54.116176+00', '1815be94-353b-473c-a49d-c8caa2445010'),
	('0ac3424b-082a-4d84-b53b-c4adbaf4f1a9', NULL, '2025-05-21 05:08:54.116176+00', 'f66e408e-637c-412f-91f1-20891b3a7f07'),
	('3eeb7115-fd65-48d2-9a06-a9929f6283a7', NULL, '2025-05-21 05:08:54.116176+00', '8062a571-6431-483f-bb60-2c1d7d927625'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:08:54.116176+00', 'c3e267d5-9475-4386-80fe-1b33b82bd0a8'),
	('eca02431-c053-4bb5-9066-195ea582a620', NULL, '2025-05-21 05:08:54.116176+00', 'ae03e416-f887-4f3d-a459-5e398dfe1a6a'),
	('de8cbc91-854c-4c7f-a734-8427c82ed3a2', NULL, '2025-05-21 05:08:54.116176+00', '5e471afb-7477-47cf-9d15-6f4a64fb89ca'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:08:54.116176+00', '4545ee17-a5af-473d-be19-ed6aacf48a27'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:08:54.116176+00', '11fec6ce-43f6-4ad9-9363-4c0b23cc10d1'),
	('9ac71b1f-7ad8-4e04-90ca-08148f5cba61', NULL, '2025-05-21 05:08:54.563939+00', '5deccf72-d384-4df6-a5de-244dc76c72ca'),
	('ea5677aa-f1e9-43de-9433-102c2f4b717d', NULL, '2025-05-21 05:08:54.563939+00', 'b9b126f7-ac11-45b4-90ce-89ebbe1c5260'),
	('0ac3424b-082a-4d84-b53b-c4adbaf4f1a9', NULL, '2025-05-21 05:08:54.563939+00', '8e9d4b2d-1b79-42c8-accd-974416f8dc75'),
	('3eeb7115-fd65-48d2-9a06-a9929f6283a7', NULL, '2025-05-21 05:08:54.563939+00', '1c23b978-5f20-4c13-b2a1-da0d30583225'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:08:54.563939+00', 'd700b38e-68c2-4305-8546-57da55fdf4ef'),
	('eca02431-c053-4bb5-9066-195ea582a620', NULL, '2025-05-21 05:08:54.563939+00', '35ee6151-7caf-4c6c-b6cf-33395def2505'),
	('de8cbc91-854c-4c7f-a734-8427c82ed3a2', NULL, '2025-05-21 05:08:54.563939+00', 'fbbe21e6-f7f1-4178-8417-3b73284c1e1d'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:08:54.563939+00', 'f131895f-e8df-40a1-87c6-4691371ebd1e'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:08:54.563939+00', 'c6ef78bf-b779-4eda-9170-f7912850e319'),
	('9ac71b1f-7ad8-4e04-90ca-08148f5cba61', NULL, '2025-05-21 05:08:54.947433+00', '5364f31b-96b9-4bed-a98c-f2fec2ebae56'),
	('ea5677aa-f1e9-43de-9433-102c2f4b717d', NULL, '2025-05-21 05:08:54.947433+00', 'e745c2ae-391f-4984-a428-a546c78d0208'),
	('0ac3424b-082a-4d84-b53b-c4adbaf4f1a9', NULL, '2025-05-21 05:08:54.947433+00', '629ab163-aab1-4ed1-a88d-29ebe9709866'),
	('3eeb7115-fd65-48d2-9a06-a9929f6283a7', NULL, '2025-05-21 05:08:54.947433+00', '51e4719f-e3e5-4b2a-a2ae-2ada5f067f53'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:08:54.947433+00', 'e35a5e03-31c4-45e6-9cf4-b2d60e1a611c'),
	('eca02431-c053-4bb5-9066-195ea582a620', NULL, '2025-05-21 05:08:54.947433+00', '7b5f8824-386f-4f5b-b13f-a6617877dcc4'),
	('de8cbc91-854c-4c7f-a734-8427c82ed3a2', NULL, '2025-05-21 05:08:54.947433+00', '7a4781b4-fcd0-4c13-a491-2e82c299c1eb'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:08:54.947433+00', '62fec590-886e-4bd4-8ab5-2fdeec7ba238'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:08:54.947433+00', 'f67fd3c5-50ee-4ae8-bfb5-80d6947a233b'),
	('9ac71b1f-7ad8-4e04-90ca-08148f5cba61', NULL, '2025-05-21 05:09:01.777871+00', '0094df6b-7551-43c6-bcd1-c7b1a041b179'),
	('ea5677aa-f1e9-43de-9433-102c2f4b717d', NULL, '2025-05-21 05:09:01.777871+00', '55c3f46a-5682-4c9d-9833-39a063b29303'),
	('0ac3424b-082a-4d84-b53b-c4adbaf4f1a9', NULL, '2025-05-21 05:09:01.777871+00', '0cb4ce10-1e81-47fa-96f5-c62f103bd97c'),
	('3eeb7115-fd65-48d2-9a06-a9929f6283a7', NULL, '2025-05-21 05:09:01.777871+00', 'd9e7a7d7-e461-4d96-8e12-facaad982295'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:09:01.777871+00', 'd7424d12-fb51-4338-955f-ef7a9d53e983'),
	('eca02431-c053-4bb5-9066-195ea582a620', NULL, '2025-05-21 05:09:01.777871+00', '6523e168-b11c-445f-a942-696a337f67e9'),
	('de8cbc91-854c-4c7f-a734-8427c82ed3a2', NULL, '2025-05-21 05:09:01.777871+00', '62e5bfcd-913f-4dfe-a6fc-90fa168fc19c'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:01.777871+00', 'c986124b-f276-4dfc-b5af-794bb5c57aa8'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:09:01.777871+00', '0567db9f-37cf-48e0-b79c-e52f5d8844ee'),
	('9ac71b1f-7ad8-4e04-90ca-08148f5cba61', NULL, '2025-05-21 05:09:07.005711+00', 'f2434317-8eec-4cd2-a671-485f359e15cc'),
	('0ac3424b-082a-4d84-b53b-c4adbaf4f1a9', NULL, '2025-05-21 05:09:07.005711+00', '3fa8c1bd-3c89-4382-aba2-ea2f81d4f277'),
	('3eeb7115-fd65-48d2-9a06-a9929f6283a7', NULL, '2025-05-21 05:09:07.005711+00', 'aa11aa8e-4e1f-4c10-affa-637335a606cd'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:09:07.005711+00', '3862f97e-9afa-4a7f-b2c1-be3f8d5ef72e'),
	('eca02431-c053-4bb5-9066-195ea582a620', NULL, '2025-05-21 05:09:07.005711+00', 'f57de560-90b9-4be3-8aab-e10b46d8676a'),
	('de8cbc91-854c-4c7f-a734-8427c82ed3a2', NULL, '2025-05-21 05:09:07.005711+00', 'd056423d-3be5-4f60-87b5-90a1591e0b54'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:07.005711+00', 'c78cef88-9e00-4981-87cf-63a08ec7c2a0'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:09:07.005711+00', '7a68768f-cb39-400c-b4bb-1ce83d3a7088'),
	('0ac3424b-082a-4d84-b53b-c4adbaf4f1a9', NULL, '2025-05-21 05:09:10.507729+00', 'ef5f6cdc-5116-4ec5-be27-7866f4a2c220'),
	('3eeb7115-fd65-48d2-9a06-a9929f6283a7', NULL, '2025-05-21 05:09:10.507729+00', '48246516-cb6f-49b0-8a00-f5cf7c287e23'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:09:10.507729+00', '1e64cf81-9739-4567-ad10-9c524fcd2d94'),
	('eca02431-c053-4bb5-9066-195ea582a620', NULL, '2025-05-21 05:09:10.507729+00', 'c5499656-aaff-457c-976b-3b44a244eb34'),
	('de8cbc91-854c-4c7f-a734-8427c82ed3a2', NULL, '2025-05-21 05:09:10.507729+00', 'fef9cda5-2406-48bc-9ce3-07642096efdd'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:10.507729+00', '4d9df197-373c-401d-983d-6a7c1603ce01'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:09:10.507729+00', 'fb158a93-7e20-40da-bc5d-c361f3165ca2'),
	('3eeb7115-fd65-48d2-9a06-a9929f6283a7', NULL, '2025-05-21 05:09:13.254243+00', '11c004a3-4879-4f43-b545-f5ffeab1a466'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:09:13.254243+00', '661259a7-f8bc-4535-836c-1a2dd7666818'),
	('eca02431-c053-4bb5-9066-195ea582a620', NULL, '2025-05-21 05:09:13.254243+00', 'fc35bde1-74d0-4bc8-a9e3-157d72d87cc5'),
	('de8cbc91-854c-4c7f-a734-8427c82ed3a2', NULL, '2025-05-21 05:09:13.254243+00', '0ea87d41-65dc-4bf1-8503-e100c610930b'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:13.254243+00', '894b076c-103a-49b2-aea4-83e78db10213'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:09:13.254243+00', '2221fbc7-1155-47af-8960-b82447c44e5c'),
	('3eeb7115-fd65-48d2-9a06-a9929f6283a7', NULL, '2025-05-21 05:09:13.399162+00', '7e2f2205-5045-4e3c-8495-c5339d5f9949'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:09:13.399162+00', '3c605773-bf4e-4d35-9317-a5e4b70c627c'),
	('eca02431-c053-4bb5-9066-195ea582a620', NULL, '2025-05-21 05:09:13.399162+00', '1a525581-31a4-402e-b0fe-e6466e32ee48'),
	('de8cbc91-854c-4c7f-a734-8427c82ed3a2', NULL, '2025-05-21 05:09:13.399162+00', '18f5eb39-3aac-4ae9-a8ff-3c15d6bced46'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:13.399162+00', '2dbe7493-3a0d-4045-bc4e-4ae33858c81a'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:09:13.399162+00', '3a8aeef7-15c5-4b4f-8c89-d5bdf73688ae'),
	('3eeb7115-fd65-48d2-9a06-a9929f6283a7', NULL, '2025-05-21 05:09:13.789362+00', '37376260-6356-45d5-bcd7-945e54a867e2'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:09:13.789362+00', '481eba18-2bfa-41c9-835b-76b097b8cdfa'),
	('eca02431-c053-4bb5-9066-195ea582a620', NULL, '2025-05-21 05:09:13.789362+00', 'a28d0ac5-9614-44c3-882b-8584998849ae'),
	('de8cbc91-854c-4c7f-a734-8427c82ed3a2', NULL, '2025-05-21 05:09:13.789362+00', '68d4e0c4-36ba-4ba4-ac58-cf25609393be'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:13.789362+00', '4dc9f261-ee81-4da2-ba7b-e9526e9c3ff2'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:09:13.789362+00', '223119f3-31b6-4c13-9b8b-3f07a015110c'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:09:19.658134+00', '6a9afc74-0db7-40b3-bf07-dc53c1f1acbb'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:09:20.006782+00', 'ae9afedf-1fdd-45b7-bb0a-71f4ea0647e6'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:09:20.339685+00', '79c45a40-5e67-4172-ba90-dd53870c09a4'),
	('a73bc809-0f9a-4956-9435-d7a13cdb066e', NULL, '2025-05-21 05:09:20.779421+00', 'dfe6686c-9da2-4069-a65e-ece1478357ea'),
	('eca02431-c053-4bb5-9066-195ea582a620', NULL, '2025-05-21 05:09:24.754224+00', '213ed762-ed2d-4145-958b-54e8ad3b5b29'),
	('de8cbc91-854c-4c7f-a734-8427c82ed3a2', NULL, '2025-05-21 05:09:24.754224+00', '3ac03cca-8956-4996-b198-e5e653eb16b8'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:24.754224+00', '3533f1ec-7ef8-4f11-9083-ede533a9b25e'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:09:24.754224+00', '1d8fd0d4-6b40-40c1-9b3e-382f1f5db5ac'),
	('de8cbc91-854c-4c7f-a734-8427c82ed3a2', NULL, '2025-05-21 05:09:28.503857+00', 'a7e96f38-f9cf-4154-ab3b-1afc2432b037'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:31.695039+00', '0d53245f-686f-42a1-a6d0-eeddf93dce85'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:09:31.695039+00', '5b1c766a-4c7e-4dd7-be44-b8e5a66a7880'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:32.1116+00', '88a60993-89bd-4f17-9883-40e7dd6379ce'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:09:32.1116+00', '5eb1deb5-0d55-4ee1-ac50-ca1093d87d38'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:32.452754+00', '3b51534e-4b2a-4ed5-9001-e5c31911e510'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:09:32.452754+00', '0cbf2afa-e81e-496a-9371-bc26be77e4c0'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:32.897339+00', 'afec502c-faba-45d5-84a8-8082e9a3dc33'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:09:32.897339+00', '7506f117-4468-4893-af38-20c50a1504ab'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:33.061864+00', '6abd79fc-9868-4d13-9042-f03990dcd020'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:09:33.061864+00', 'bb2c2304-69ca-4b41-a8fd-5d3f6398a47e'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:34.215849+00', '448939bb-f96b-4ef3-a95f-dbde4af4db59'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', NULL, '2025-05-21 05:09:34.215849+00', 'fa020c81-0584-4394-b55a-d5e4615c8f32'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:37.043599+00', '3a85d5bd-ee4a-4778-8333-2af6f7723abb'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:37.331784+00', 'b151ef55-80a3-41e4-84f1-c694ad27e82d'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:37.658013+00', 'f3f41f0c-ed62-47c8-b5d2-fd5216a7cf8d'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:38.19152+00', '94f15af3-da8c-41ea-9a7f-89ab8049d51c'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', NULL, '2025-05-21 05:09:38.488558+00', '87153b67-a6a5-4a1d-ad93-db6a8292e3c5'),
	('d7df1775-74e0-4dd3-8b3a-2d5ffdca10c1', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '2025-05-21 06:26:54.324533+00', '78649dc9-cf68-4f30-b102-18de8613c7cc'),
	('428b8d7f-5eb8-469f-8f94-043f74658d16', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '2025-05-22 13:42:10.765029+00', 'efa2c37f-ec28-4ef4-a293-b9a265aad3ae');


--
-- Data for Name: therapist_verification_requests; Type: TABLE DATA; Schema: public; Owner: postgres
--

INSERT INTO "public"."therapist_verification_requests" ("id", "user_id", "id_document_path", "certificate_paths", "status", "requested_at", "reviewed_at", "reviewer_notes", "created_at", "updated_at") VALUES
	('a6723110-98b0-463b-a9ce-0bfcf0ae9185', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f/id/id_8458bab3-1fb1-4eb7-8cad-f555bc58fc8f_1747926494565.pdf', '{8458bab3-1fb1-4eb7-8cad-f555bc58fc8f/certificates/cert_8458bab3-1fb1-4eb7-8cad-f555bc58fc8f_1747926495370_Sandu_Elena_-_atestat_psihoterapie.pdf,8458bab3-1fb1-4eb7-8cad-f555bc58fc8f/certificates/cert_8458bab3-1fb1-4eb7-8cad-f555bc58fc8f_1747926496523_Sandu_Elena_clinica_autonom.pdf}', 'approved', '2025-05-22 15:08:15.099022+00', '2025-05-23 05:16:41.411+00', NULL, '2025-05-22 15:08:15.099022+00', '2025-05-23 05:16:39.567445+00'),
	('8e8bb7ae-9f78-4910-976d-daab56cf44d3', '65da1664-c0da-4c49-88c8-dce05acc1374', '65da1664-c0da-4c49-88c8-dce05acc1374/id/id_65da1664-c0da-4c49-88c8-dce05acc1374_1747905470425.jpg', '{65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905471014_Diploma_Formator.pdf,65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905471524_Diploma_Grand_Master_5-6.pdf,65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905471777_Diploma_Licenta-_ANAMARIA_BUZATU.pdf,65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905472178_Diploma_Reiki_Gendai.pdf,65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905472480_Diploma_Reiki.pdf,65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905472837_Dragon_Reiki___Level_1_Certificate!.pdf,65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905473507_Dragon_Reiki___Level_2_Certificate!.pdf,65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905474237_Moon_Reiki_Certificate!.pdf}', 'approved', '2025-05-22 09:17:54.994147+00', '2025-05-23 05:16:44.429+00', NULL, '2025-05-22 09:17:54.994147+00', '2025-05-23 05:16:42.588974+00'),
	('cdb30394-cbdd-4beb-a4b4-2bdbb2f6e60d', 'd3275dfe-f4df-44fc-acaa-659e92369e66', 'd3275dfe-f4df-44fc-acaa-659e92369e66/id/id_d3275dfe-f4df-44fc-acaa-659e92369e66_1747984802036.pdf', '{d3275dfe-f4df-44fc-acaa-659e92369e66/certificates/cert_d3275dfe-f4df-44fc-acaa-659e92369e66_1747984802691_36.Dosar_Jilavu_Danut_Atestat_Psihologie_Clinica.pdf}', 'pending', '2025-05-23 07:20:04.521756+00', NULL, NULL, '2025-05-23 07:20:04.521756+00', '2025-05-23 07:20:04.521756+00'),
	('4cb574f4-dfbf-493c-9455-9bafcb4b0d15', '1e8e19fd-7346-4d83-807e-404c01903baf', '1e8e19fd-7346-4d83-807e-404c01903baf/id/id_1e8e19fd-7346-4d83-807e-404c01903baf_1747952204930.jpg', '{1e8e19fd-7346-4d83-807e-404c01903baf/certificates/cert_1e8e19fd-7346-4d83-807e-404c01903baf_1747952205854_hero-image.jpg}', 'approved', '2025-05-22 22:16:45.716877+00', '2025-05-23 05:16:12.492+00', NULL, '2025-05-22 22:16:45.716877+00', '2025-05-23 05:16:10.63383+00'),
	('16b1cfb8-e43c-4548-8c6d-d6a0a4f88dc3', '3a317800-976d-4277-a491-27d7962bb16b', '3a317800-976d-4277-a491-27d7962bb16b/id/id_3a317800-976d-4277-a491-27d7962bb16b_1747841433375.JPG', '{"3a317800-976d-4277-a491-27d7962bb16b/certificates/cert_3a317800-976d-4277-a491-27d7962bb16b_1747841433981_ChatGPT_Image_14_mai_2025,_10_12_27.png"}', 'approved', '2025-05-21 15:30:35.171+00', '2025-05-21 15:43:45.922+00', NULL, '2025-05-21 15:30:35.171+00', '2025-05-21 15:43:46.482936+00'),
	('24010d3b-ec3b-4b7f-ba5d-28481d61327b', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', 'de7ba501-a94e-4f86-81b3-0afe662ae8de/id/id_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930307418.pdf', '{de7ba501-a94e-4f86-81b3-0afe662ae8de/certificates/cert_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930308169_Coaching_Constellations_-_1to1_-_Dan_Magirescu_(03.2023).pdf,de7ba501-a94e-4f86-81b3-0afe662ae8de/certificates/cert_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930308992_Coaching_Constellations_-_Fundamentals_I_-_Dan_Magirescu_(02.2023).pdf,de7ba501-a94e-4f86-81b3-0afe662ae8de/certificates/cert_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930309262_Coaching_Constellations_-_Fundamentals_II_-_Dan_Magirescu_(06.2023).pdf,de7ba501-a94e-4f86-81b3-0afe662ae8de/certificates/cert_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930309561_Coaching_Constellations_-_Fundamentals_III_-_Dan_Magirescu_(11.2023).pdf,de7ba501-a94e-4f86-81b3-0afe662ae8de/certificates/cert_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930310030_Coaching_Constellations_-_Somatic_-_Dan_Magirescu_(10.2023).pdf,de7ba501-a94e-4f86-81b3-0afe662ae8de/certificates/cert_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930310582_Coaching_Constellations_-_Team_Coaching_-_Dan_Magirescu_(11.2023).pdf,de7ba501-a94e-4f86-81b3-0afe662ae8de/certificates/cert_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930310979_One2Coach_-_Certificat_ACSTH__Dan_Magirescu_(10.2021).pdf}', 'approved', '2025-05-22 16:11:51.281222+00', '2025-05-23 05:16:38.401+00', NULL, '2025-05-22 16:11:51.281222+00', '2025-05-23 05:16:36.577775+00');


--
-- Data for Name: buckets; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--

INSERT INTO "storage"."buckets" ("id", "name", "owner", "created_at", "updated_at", "public", "avif_autodetection", "file_size_limit", "allowed_mime_types", "owner_id") VALUES
	('therapist_profiles', 'therapist_profiles', NULL, '2025-04-29 15:20:46.320043+00', '2025-04-29 15:20:46.320043+00', true, false, NULL, NULL, NULL),
	('therapists.verification.documents', 'therapists.verification.documents', NULL, '2025-05-16 14:25:21.981078+00', '2025-05-16 14:25:21.981078+00', false, false, NULL, NULL, NULL);


--
-- Data for Name: objects; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--

INSERT INTO "storage"."objects" ("id", "bucket_id", "name", "owner", "created_at", "updated_at", "last_accessed_at", "metadata", "version", "owner_id", "user_metadata") VALUES
	('f38f1bfc-eed4-4c85-8cfd-9c74cf50dfa7', 'therapist_profiles', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6-1745940155436.png', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '2025-04-29 15:22:38.125663+00', '2025-04-29 15:22:38.125663+00', '2025-04-29 15:22:38.125663+00', '{"eTag": "\"baec1a97aa95918c45f4612bac28b5a6\"", "size": 464898, "mimetype": "image/png", "cacheControl": "max-age=3600", "lastModified": "2025-04-29T15:22:39.000Z", "contentLength": 464898, "httpStatusCode": 200}', '4c478a98-84a8-48c9-8007-5cdfb0047ef0', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '{}'),
	('fb7fbc04-1529-4a8d-9a17-c28ed357279a', 'therapist_profiles', '20d55537-6f54-41d6-98a6-474174099d17-1747777448865.jpg', '20d55537-6f54-41d6-98a6-474174099d17', '2025-05-20 21:44:08.941509+00', '2025-05-20 21:44:08.941509+00', '2025-05-20 21:44:08.941509+00', '{"eTag": "\"25e1f5fde0da5ce6d77953189daaded5\"", "size": 109032, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-20T21:44:09.000Z", "contentLength": 109032, "httpStatusCode": 200}', '7d10f168-2c6c-4c4b-90bd-33c516c95132', '20d55537-6f54-41d6-98a6-474174099d17', '{}'),
	('33ab8321-f815-42ad-9a9e-a7db6f7261fb', 'therapist_profiles', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6-1745940225353.png', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '2025-04-29 15:23:47.987669+00', '2025-04-29 15:23:47.987669+00', '2025-04-29 15:23:47.987669+00', '{"eTag": "\"baec1a97aa95918c45f4612bac28b5a6\"", "size": 464898, "mimetype": "image/png", "cacheControl": "max-age=3600", "lastModified": "2025-04-29T15:23:48.000Z", "contentLength": 464898, "httpStatusCode": 200}', 'bb4a5bbe-65cd-41cc-b5b7-dcf12dfbd4b7', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '{}'),
	('af74e8b9-16ca-45f4-acc2-ee2ab4493265', 'therapist_profiles', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6-1745941150454.png', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '2025-04-29 15:39:13.081983+00', '2025-04-29 15:39:13.081983+00', '2025-04-29 15:39:13.081983+00', '{"eTag": "\"baec1a97aa95918c45f4612bac28b5a6\"", "size": 464898, "mimetype": "image/png", "cacheControl": "max-age=3600", "lastModified": "2025-04-29T15:39:14.000Z", "contentLength": 464898, "httpStatusCode": 200}', '26b8d0c2-4bbd-4b04-acbc-e8a95ba9e69d', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '{}'),
	('1d4fc6a1-7e95-4113-992f-6f342a5d2d5b', 'therapist_profiles', 'ae26134b-38c8-4748-8770-5b73d79cae08-1747860315525.JPG', 'ae26134b-38c8-4748-8770-5b73d79cae08', '2025-05-21 20:45:16.881484+00', '2025-05-21 20:45:16.881484+00', '2025-05-21 20:45:16.881484+00', '{"eTag": "\"a29370689973b3aa335fa49e8252d7b9\"", "size": 1725396, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-21T20:45:17.000Z", "contentLength": 1725396, "httpStatusCode": 200}', 'd423ed88-a988-41cf-bb4f-fbfccb3345f8', 'ae26134b-38c8-4748-8770-5b73d79cae08', '{}'),
	('1de1bba1-e610-4a2e-bec4-1be991563619', 'therapist_profiles', 'df1d2f97-8f64-4160-a909-9039e6619ae3-1747122332673.jpg', 'df1d2f97-8f64-4160-a909-9039e6619ae3', '2025-05-13 07:56:51.245299+00', '2025-05-13 07:56:51.245299+00', '2025-05-13 07:56:51.245299+00', '{"eTag": "\"3138b71b74ed507403b532804a688749-4\"", "size": 17967268, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-13T07:56:51.000Z", "contentLength": 17967268, "httpStatusCode": 200}', 'de7b6448-a0fc-4e81-9b22-b75e98558783', 'df1d2f97-8f64-4160-a909-9039e6619ae3', '{}'),
	('0c116924-ee98-4c04-a547-94dba57154e8', 'therapists.verification.documents', '65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905472480_Diploma_Reiki.pdf', '65da1664-c0da-4c49-88c8-dce05acc1374', '2025-05-22 09:17:52.976571+00', '2025-05-22 09:17:52.976571+00', '2025-05-22 09:17:52.976571+00', '{"eTag": "\"e2d71379cc14e90ebc236993be216010\"", "size": 255619, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T09:17:53.000Z", "contentLength": 255619, "httpStatusCode": 200}', '66ad7448-1013-4bbe-9954-8aebcdf38f54', '65da1664-c0da-4c49-88c8-dce05acc1374', '{}'),
	('0ee260f8-9818-496c-a1bf-79538243bbba', 'therapist_profiles', 'df1d2f97-8f64-4160-a909-9039e6619ae3-1747122375281.jpg', 'df1d2f97-8f64-4160-a909-9039e6619ae3', '2025-05-13 07:57:34.122177+00', '2025-05-13 07:57:34.122177+00', '2025-05-13 07:57:34.122177+00', '{"eTag": "\"3138b71b74ed507403b532804a688749-4\"", "size": 17967268, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-13T07:57:34.000Z", "contentLength": 17967268, "httpStatusCode": 200}', '841de04e-e833-4ca1-9deb-3f332799948f', 'df1d2f97-8f64-4160-a909-9039e6619ae3', '{}'),
	('4a75c78a-1cc5-42b2-955d-49e3077ca78d', 'therapist_profiles', 'df1d2f97-8f64-4160-a909-9039e6619ae3-1747122427709.jpg', 'df1d2f97-8f64-4160-a909-9039e6619ae3', '2025-05-13 07:59:08.520569+00', '2025-05-13 07:59:08.520569+00', '2025-05-13 07:59:08.520569+00', '{"eTag": "\"3138b71b74ed507403b532804a688749-4\"", "size": 17967268, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-13T07:59:08.000Z", "contentLength": 17967268, "httpStatusCode": 200}', '421b078c-d970-4e85-b810-dba0686a7647', 'df1d2f97-8f64-4160-a909-9039e6619ae3', '{}'),
	('061bf9d6-914d-4e81-b83f-c284c517f87e', 'therapist_profiles', 'df1d2f97-8f64-4160-a909-9039e6619ae3-1747122750796.jpg', 'df1d2f97-8f64-4160-a909-9039e6619ae3', '2025-05-13 08:04:12.470482+00', '2025-05-13 08:04:12.470482+00', '2025-05-13 08:04:12.470482+00', '{"eTag": "\"3138b71b74ed507403b532804a688749-4\"", "size": 17967268, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-13T08:04:12.000Z", "contentLength": 17967268, "httpStatusCode": 200}', 'cd65674a-c5df-4512-8553-b976956b6381', 'df1d2f97-8f64-4160-a909-9039e6619ae3', '{}'),
	('92a09e38-3804-4f17-b7b8-17ea35899a92', 'therapist_profiles', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca-1747127764743.jpg', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', '2025-05-13 09:16:10.187841+00', '2025-05-13 09:16:10.187841+00', '2025-05-13 09:16:10.187841+00', '{"eTag": "\"c20850a53a2f2bd10911964f8883e4c2\"", "size": 3603805, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-13T09:16:11.000Z", "contentLength": 3603805, "httpStatusCode": 200}', '19412f7a-605d-4d4b-bdf9-2ba22ef0ac17', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', '{}'),
	('06aa8bda-5cab-4128-99ec-1ed629793e8e', 'therapist_profiles', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca-1747127777404.jpg', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', '2025-05-13 09:16:24.8069+00', '2025-05-13 09:16:24.8069+00', '2025-05-13 09:16:24.8069+00', '{"eTag": "\"c20850a53a2f2bd10911964f8883e4c2\"", "size": 3603805, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-13T09:16:25.000Z", "contentLength": 3603805, "httpStatusCode": 200}', '783ccba7-bb03-4726-93d6-7642b4b5857a', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', '{}'),
	('64f35cfd-b815-4565-9545-d32ffed7b246', 'therapist_profiles', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca-1747127788653.jpg', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', '2025-05-13 09:16:32.514741+00', '2025-05-13 09:16:32.514741+00', '2025-05-13 09:16:32.514741+00', '{"eTag": "\"c20850a53a2f2bd10911964f8883e4c2\"", "size": 3603805, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-13T09:16:33.000Z", "contentLength": 3603805, "httpStatusCode": 200}', 'b9d1a6f6-7214-43ee-afb1-a16651971fc4', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', '{}'),
	('be8614a6-d4d9-4cea-9f0c-d8f4e64fe084', 'therapist_profiles', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca-1747127802370.jpg', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', '2025-05-13 09:16:45.605719+00', '2025-05-13 09:16:45.605719+00', '2025-05-13 09:16:45.605719+00', '{"eTag": "\"c20850a53a2f2bd10911964f8883e4c2\"", "size": 3603805, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-13T09:16:46.000Z", "contentLength": 3603805, "httpStatusCode": 200}', '44483db3-48c7-4863-91d3-45302d3a8e42', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', '{}'),
	('02c7b20a-c3e5-4293-9505-0882d2fe13e8', 'therapist_profiles', '1e8e19fd-7346-4d83-807e-404c01903baf-1747785649870.jpg', '1e8e19fd-7346-4d83-807e-404c01903baf', '2025-05-21 00:00:49.820166+00', '2025-05-21 00:00:49.820166+00', '2025-05-21 00:00:49.820166+00', '{"eTag": "\"3272b0bbef52bdca010f760a4982c970\"", "size": 85279, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-21T00:00:50.000Z", "contentLength": 85279, "httpStatusCode": 200}', '0b4292b7-abd6-4434-9809-9cf1af26a0b9', '1e8e19fd-7346-4d83-807e-404c01903baf', '{}'),
	('beb3b8c4-72cc-48ce-971e-dc56658b09fb', 'therapist_profiles', 'c07e8742-9b26-4257-80d8-81ea920e3722-1747162142760.jpg', 'c07e8742-9b26-4257-80d8-81ea920e3722', '2025-05-13 18:49:05.485874+00', '2025-05-13 18:49:05.485874+00', '2025-05-13 18:49:05.485874+00', '{"eTag": "\"b04ab1ec299229f4a91afb8060c66c78\"", "size": 643975, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-13T18:49:06.000Z", "contentLength": 643975, "httpStatusCode": 200}', '2f0b4ffc-fed7-4d4f-ab0a-21245ad29cea', 'c07e8742-9b26-4257-80d8-81ea920e3722', '{}'),
	('81f09f9f-a870-4451-a40d-01b7d65c4a01', 'therapist_profiles', 'c07e8742-9b26-4257-80d8-81ea920e3722-1747162149357.jpg', 'c07e8742-9b26-4257-80d8-81ea920e3722', '2025-05-13 18:49:11.864401+00', '2025-05-13 18:49:11.864401+00', '2025-05-13 18:49:11.864401+00', '{"eTag": "\"b04ab1ec299229f4a91afb8060c66c78\"", "size": 643975, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-13T18:49:12.000Z", "contentLength": 643975, "httpStatusCode": 200}', '04b22398-8532-4691-8c6c-6f3ee07bc49a', 'c07e8742-9b26-4257-80d8-81ea920e3722', '{}'),
	('dd11d2fe-edd4-4087-bfde-3c60a2ff8662', 'therapist_profiles', 'c07e8742-9b26-4257-80d8-81ea920e3722-1747162224120.jpg', 'c07e8742-9b26-4257-80d8-81ea920e3722', '2025-05-13 18:50:26.434065+00', '2025-05-13 18:50:26.434065+00', '2025-05-13 18:50:26.434065+00', '{"eTag": "\"96d3b2a1e41a77b66aa3cc0c574cc9e3\"", "size": 101381, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-13T18:50:27.000Z", "contentLength": 101381, "httpStatusCode": 200}', '11c857d0-f578-4773-82f8-51c24a0882ec', 'c07e8742-9b26-4257-80d8-81ea920e3722', '{}'),
	('1bc7ad82-af96-433e-823f-10e8578fb982', 'therapist_profiles', 'c07e8742-9b26-4257-80d8-81ea920e3722-1747162234395.jpg', 'c07e8742-9b26-4257-80d8-81ea920e3722', '2025-05-13 18:50:36.571245+00', '2025-05-13 18:50:36.571245+00', '2025-05-13 18:50:36.571245+00', '{"eTag": "\"96d3b2a1e41a77b66aa3cc0c574cc9e3\"", "size": 101381, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-13T18:50:37.000Z", "contentLength": 101381, "httpStatusCode": 200}', 'a57f47ad-a756-4df5-9c7d-51af413a2ad6', 'c07e8742-9b26-4257-80d8-81ea920e3722', '{}'),
	('620bb46a-8c20-4b33-9af9-9f5b8053b85f', 'therapist_profiles', 'c07e8742-9b26-4257-80d8-81ea920e3722-1747166856783.jpg', 'c07e8742-9b26-4257-80d8-81ea920e3722', '2025-05-13 20:07:36.576531+00', '2025-05-13 20:07:36.576531+00', '2025-05-13 20:07:36.576531+00', '{"eTag": "\"e6bf4af751af2385c821ee9ce8a950dc\"", "size": 248819, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-13T20:07:37.000Z", "contentLength": 248819, "httpStatusCode": 200}', 'c96eb5a7-dae2-448a-9d07-90b23350b093', 'c07e8742-9b26-4257-80d8-81ea920e3722', '{}'),
	('ac199a69-7ad7-4472-b2d6-8c0464514761', 'therapist_profiles', 'c07e8742-9b26-4257-80d8-81ea920e3722-1747166896784.jpg', 'c07e8742-9b26-4257-80d8-81ea920e3722', '2025-05-13 20:08:16.628522+00', '2025-05-13 20:08:16.628522+00', '2025-05-13 20:08:16.628522+00', '{"eTag": "\"e6bf4af751af2385c821ee9ce8a950dc\"", "size": 248819, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-13T20:08:17.000Z", "contentLength": 248819, "httpStatusCode": 200}', '9b6843b1-e699-48f0-bad2-be6d3a8b71c8', 'c07e8742-9b26-4257-80d8-81ea920e3722', '{}'),
	('adb477eb-dcbc-4478-84af-ca7cbd3a3db9', 'therapist_profiles', '12389e53-ab41-4ff5-90ee-c3593e2b84cc-1747230602365.jpg', '12389e53-ab41-4ff5-90ee-c3593e2b84cc', '2025-05-14 13:50:01.338333+00', '2025-05-14 13:50:01.338333+00', '2025-05-14 13:50:01.338333+00', '{"eTag": "\"4296badaba60c10cf0c73c95aa9d1be5\"", "size": 106966, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-14T13:50:02.000Z", "contentLength": 106966, "httpStatusCode": 200}', 'e69f219a-f3a0-4bf7-94ee-1817a663cac1', '12389e53-ab41-4ff5-90ee-c3593e2b84cc', '{}'),
	('9d7640ca-5fe1-465a-98eb-2f84f57c4065', 'therapist_profiles', '76f53ea1-d6bf-4bf7-b88a-918e4062766e-1747242235612.png', '76f53ea1-d6bf-4bf7-b88a-918e4062766e', '2025-05-14 17:03:56.713702+00', '2025-05-14 17:03:56.713702+00', '2025-05-14 17:03:56.713702+00', '{"eTag": "\"4c42628d568af4ef197aaeb69ac22121\"", "size": 1931204, "mimetype": "image/png", "cacheControl": "max-age=3600", "lastModified": "2025-05-14T17:03:57.000Z", "contentLength": 1931204, "httpStatusCode": 200}', '121d99ea-7ce0-4d8a-862a-ddad43ee8773', '76f53ea1-d6bf-4bf7-b88a-918e4062766e', '{}'),
	('8db90c1b-15b0-45c4-a648-a029f9837a0b', 'therapist_profiles', 'f10db344-d6f0-4ae3-8ea0-4b1cb2a80894-1747245004546.jpeg', 'f10db344-d6f0-4ae3-8ea0-4b1cb2a80894', '2025-05-14 17:50:05.700017+00', '2025-05-14 17:50:05.700017+00', '2025-05-14 17:50:05.700017+00', '{"eTag": "\"7c13bf531446b0f4ad7f1388ecaab1be\"", "size": 2053351, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-14T17:50:06.000Z", "contentLength": 2053351, "httpStatusCode": 200}', 'd267b9a5-9935-4fa1-b84d-f8a05dcd1a0c', 'f10db344-d6f0-4ae3-8ea0-4b1cb2a80894', '{}'),
	('ca0eaa44-3e07-4568-a5d1-28e7e6dcf46c', 'therapist_profiles', '6a70d9b5-4fb8-46f7-975b-5887fd4e47de-1747814697002.JPG', '6a70d9b5-4fb8-46f7-975b-5887fd4e47de', '2025-05-21 08:04:57.655352+00', '2025-05-21 08:04:57.655352+00', '2025-05-21 08:04:57.655352+00', '{"eTag": "\"8e2f51c8d8c20145142c93ae4e8fbecc\"", "size": 5109479, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-21T08:04:58.000Z", "contentLength": 5109479, "httpStatusCode": 200}', 'fea78674-d90d-4c97-8ebb-617eb80698a8', '6a70d9b5-4fb8-46f7-975b-5887fd4e47de', '{}'),
	('231a370e-2bfb-41f2-b699-35b6727905ff', 'therapist_profiles', '07a95865-754b-4fed-ae0a-d4b69c486190-1747312277979.JPG', '07a95865-754b-4fed-ae0a-d4b69c486190', '2025-05-15 12:31:18.629968+00', '2025-05-15 12:31:18.629968+00', '2025-05-15 12:31:18.629968+00', '{"eTag": "\"8fedce3e5f88b508796610cfd5facd4c\"", "size": 239927, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-15T12:31:19.000Z", "contentLength": 239927, "httpStatusCode": 200}', '18e6c235-e341-4254-9376-33f649813045', '07a95865-754b-4fed-ae0a-d4b69c486190', '{}'),
	('d9c5ecb8-dd23-4a16-9176-8f73c736f250', 'therapist_profiles', '07a95865-754b-4fed-ae0a-d4b69c486190-1747314759948.jpg', '07a95865-754b-4fed-ae0a-d4b69c486190', '2025-05-15 13:12:40.553955+00', '2025-05-15 13:12:40.553955+00', '2025-05-15 13:12:40.553955+00', '{"eTag": "\"1b4c9da09f7ae186c1f6ca8a4e58da36\"", "size": 61894, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-15T13:12:41.000Z", "contentLength": 61894, "httpStatusCode": 200}', '22dc0cd8-3df0-4fa0-9340-60dff8dfea49', '07a95865-754b-4fed-ae0a-d4b69c486190', '{}'),
	('8901ef3b-fef6-442f-a698-53b29a57c4de', 'therapists.verification.documents', '65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905472837_Dragon_Reiki___Level_1_Certificate!.pdf', '65da1664-c0da-4c49-88c8-dce05acc1374', '2025-05-22 09:17:53.655052+00', '2025-05-22 09:17:53.655052+00', '2025-05-22 09:17:53.655052+00', '{"eTag": "\"ccd37a7dad63cf2d33b1e2e734f60d7b\"", "size": 754545, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T09:17:54.000Z", "contentLength": 754545, "httpStatusCode": 200}', 'aaddb6e2-9507-45ed-9d96-2a1b51d1f453', '65da1664-c0da-4c49-88c8-dce05acc1374', '{}'),
	('156eb806-7fd1-4449-92ad-97ea0558e410', 'therapist_profiles', '76f53ea1-d6bf-4bf7-b88a-918e4062766e-1747326255248.jpg', '76f53ea1-d6bf-4bf7-b88a-918e4062766e', '2025-05-15 16:24:15.984594+00', '2025-05-15 16:24:15.984594+00', '2025-05-15 16:24:15.984594+00', '{"eTag": "\"cda00544a973a8effb416eb1de555605\"", "size": 1327377, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-15T16:24:16.000Z", "contentLength": 1327377, "httpStatusCode": 200}', '4623fbbf-1f51-4fbf-a933-d319714c08e3', '76f53ea1-d6bf-4bf7-b88a-918e4062766e', '{}'),
	('f18d785e-2d9b-43f9-9c6b-0efa62acf659', 'therapist_profiles', '76f53ea1-d6bf-4bf7-b88a-918e4062766e-1747326285430.jpg', '76f53ea1-d6bf-4bf7-b88a-918e4062766e', '2025-05-15 16:24:45.954362+00', '2025-05-15 16:24:45.954362+00', '2025-05-15 16:24:45.954362+00', '{"eTag": "\"64f4186e90cbe516060c7b29ebd1cc30\"", "size": 664514, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-15T16:24:46.000Z", "contentLength": 664514, "httpStatusCode": 200}', 'ef36ed1d-2521-4fd0-8066-fba4aadecf3c', '76f53ea1-d6bf-4bf7-b88a-918e4062766e', '{}'),
	('fed74f80-bb5b-49b5-a515-bd6def709f4a', 'therapist_profiles', '76f53ea1-d6bf-4bf7-b88a-918e4062766e-1747326621643.png', '76f53ea1-d6bf-4bf7-b88a-918e4062766e', '2025-05-15 16:30:22.584467+00', '2025-05-15 16:30:22.584467+00', '2025-05-15 16:30:22.584467+00', '{"eTag": "\"4c42628d568af4ef197aaeb69ac22121\"", "size": 1931204, "mimetype": "image/png", "cacheControl": "max-age=3600", "lastModified": "2025-05-15T16:30:23.000Z", "contentLength": 1931204, "httpStatusCode": 200}', '1373360e-e763-4c33-ba0d-85b56d66de84', '76f53ea1-d6bf-4bf7-b88a-918e4062766e', '{}'),
	('0cf6ba28-5136-4a66-bdf5-f425a5be6482', 'therapist_profiles', '49af0fde-1e09-4899-85d0-42f87dc62ad7-1747385363731.jpg', '49af0fde-1e09-4899-85d0-42f87dc62ad7', '2025-05-16 08:49:26.170747+00', '2025-05-16 08:49:26.170747+00', '2025-05-16 08:49:26.170747+00', '{"eTag": "\"378f36594c71450dbefbd561ee8fa183-2\"", "size": 6200229, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-16T08:49:26.000Z", "contentLength": 6200229, "httpStatusCode": 200}', '5b1eb3ed-f2c4-4835-afdb-cfb9880c00b0', '49af0fde-1e09-4899-85d0-42f87dc62ad7', '{}'),
	('d9e9e6d8-bd03-446c-895f-8ce8770e08f4', 'therapist_profiles', '3e6b8532-e559-4bba-a913-9178fdb2a0bd-1747392526420.jpg', '3e6b8532-e559-4bba-a913-9178fdb2a0bd', '2025-05-16 10:48:53.331479+00', '2025-05-16 10:48:53.331479+00', '2025-05-16 10:48:53.331479+00', '{"eTag": "\"e82afca90caa29fb507683631947ab51\"", "size": 1802942, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-16T10:48:54.000Z", "contentLength": 1802942, "httpStatusCode": 200}', '381bd6d1-d150-46e7-8eea-d83af008d7a7', '3e6b8532-e559-4bba-a913-9178fdb2a0bd', '{}'),
	('95b33bb7-95a0-4a2d-bca9-46a8ed96f8c1', 'therapist_profiles', '13640682-e72c-448d-87a7-af45f1070498-1747399451163.jpg', '13640682-e72c-448d-87a7-af45f1070498', '2025-05-16 12:44:14.068446+00', '2025-05-16 12:44:14.068446+00', '2025-05-16 12:44:14.068446+00', '{"eTag": "\"df4a31a11a886e36424d81a441aed972\"", "size": 459807, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-16T12:44:14.000Z", "contentLength": 459807, "httpStatusCode": 200}', 'ca4cd129-80b6-4112-8542-f17956c7c7ac', '13640682-e72c-448d-87a7-af45f1070498', '{}'),
	('24483a4c-a1ef-4dd7-af9b-005220fe5b53', 'therapist_profiles', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370-1747816840646.jpg', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', '2025-05-21 08:40:41.68018+00', '2025-05-21 08:40:41.68018+00', '2025-05-21 08:40:41.68018+00', '{"eTag": "\"906ed10252870d8ce8e3220e911418cf\"", "size": 320513, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-21T08:40:42.000Z", "contentLength": 320513, "httpStatusCode": 200}', 'ca818846-41a2-4c45-b10a-e3cbc11ef17b', '30afa3ac-3cac-4756-a1dc-3f9a2ae8d370', '{}'),
	('ab667e6e-afcb-480e-9fac-74ff1437ef8a', 'therapist_profiles', '65da1664-c0da-4c49-88c8-dce05acc1374-1747901727216.jpg', '65da1664-c0da-4c49-88c8-dce05acc1374', '2025-05-22 08:15:28.010457+00', '2025-05-22 08:15:28.010457+00', '2025-05-22 08:15:28.010457+00', '{"eTag": "\"2d1e3e8cbd1c41ee3c1709bbb22edb8f\"", "size": 193969, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T08:15:28.000Z", "contentLength": 193969, "httpStatusCode": 200}', 'a9ee89b4-fc35-4180-b1aa-b2f05a567112', '65da1664-c0da-4c49-88c8-dce05acc1374', '{}'),
	('bbea84ba-6b1f-43cc-bce8-0fc21cb95a75', 'therapists.verification.documents', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6/id/id_e2479383-7ba2-4290-beb7-6e8d08b52ee6_1747406899770.jpg', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '2025-05-16 14:48:20.674058+00', '2025-05-16 14:48:20.674058+00', '2025-05-16 14:48:20.674058+00', '{"eTag": "\"664f0e069f2aa5de2b7d3310f33c7c09\"", "size": 473126, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-16T14:48:21.000Z", "contentLength": 473126, "httpStatusCode": 200}', '4568a379-621c-454b-b607-c0f5cd210fff', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '{}'),
	('03e9e4ef-a75b-48ca-bdf2-767c3ef4c716', 'therapists.verification.documents', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6/certificates/cert_e2479383-7ba2-4290-beb7-6e8d08b52ee6_1747406900522_Hollyland_Mic.pdf', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '2025-05-16 14:48:21.064739+00', '2025-05-16 14:48:21.064739+00', '2025-05-16 14:48:21.064739+00', '{"eTag": "\"95e6bb793e46921e10d17f0d8229ba13\"", "size": 67641, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-16T14:48:22.000Z", "contentLength": 67641, "httpStatusCode": 200}', 'ca1b036d-5bd4-4f2a-b8db-1a09d2f3713a', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '{}'),
	('19660d39-5d6e-4bc0-8957-3c591e27d480', 'therapists.verification.documents', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6/certificates/cert_e2479383-7ba2-4290-beb7-6e8d08b52ee6_1747406900902_proof_of_address_oct_2024.pdf', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '2025-05-16 14:48:21.432152+00', '2025-05-16 14:48:21.432152+00', '2025-05-16 14:48:21.432152+00', '{"eTag": "\"104a481b4c5aabeb508dda77d8059734\"", "size": 32089, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-16T14:48:22.000Z", "contentLength": 32089, "httpStatusCode": 200}', '33b48ba0-d7b4-446f-88be-34a5fcbd341f', 'e2479383-7ba2-4290-beb7-6e8d08b52ee6', '{}'),
	('bbaa0197-d35b-4cbc-a9d4-09fd5cbe2eb8', 'therapist_profiles', 'f9a83a83-6324-46d1-9e75-3eddf8edd890-1747466128645.jpg', 'f9a83a83-6324-46d1-9e75-3eddf8edd890', '2025-05-17 07:15:29.408369+00', '2025-05-17 07:15:29.408369+00', '2025-05-17 07:15:29.408369+00', '{"eTag": "\"bd6f4f71ec281ad8bdef9bdb12e1b7a7\"", "size": 56064, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-17T07:15:30.000Z", "contentLength": 56064, "httpStatusCode": 200}', '7205213d-6e06-41e4-bb3d-64fa00d39f49', 'f9a83a83-6324-46d1-9e75-3eddf8edd890', '{}'),
	('1f0be564-183c-4a7a-8471-8acde890bba0', 'therapist_profiles', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca-1747478818112.jpg', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', '2025-05-17 10:46:59.361882+00', '2025-05-17 10:46:59.361882+00', '2025-05-17 10:46:59.361882+00', '{"eTag": "\"0ea80340a5f21b1a7797851b8bce1f2d\"", "size": 322338, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-17T10:47:00.000Z", "contentLength": 322338, "httpStatusCode": 200}', '7b9394ba-700e-435b-a34b-73ac54c5d1e9', '0249dc7a-dc5a-422f-9bfc-4e2a9c2d4fca', '{}'),
	('d4465566-2857-4a26-bb06-0613b930ce64', 'therapist_profiles', '7617e0bf-ca39-47d8-a708-935afb8eaf87-1747633527344.png', '7617e0bf-ca39-47d8-a708-935afb8eaf87', '2025-05-19 05:45:27.06092+00', '2025-05-19 05:45:27.06092+00', '2025-05-19 05:45:27.06092+00', '{"eTag": "\"b5e24051aa47214a70d239b9ceb0c0b6\"", "size": 389188, "mimetype": "image/png", "cacheControl": "max-age=3600", "lastModified": "2025-05-19T05:45:27.000Z", "contentLength": 389188, "httpStatusCode": 200}', 'b1973350-55e1-44b7-a713-0a1929ab722e', '7617e0bf-ca39-47d8-a708-935afb8eaf87', '{}'),
	('2780b94a-80c0-4146-9827-405fd019e2fd', 'therapist_profiles', 'd707eee8-8de6-49fa-a4a6-00d79d6eded8-1747647474025.jpeg', 'd707eee8-8de6-49fa-a4a6-00d79d6eded8', '2025-05-19 09:37:54.686325+00', '2025-05-19 09:37:54.686325+00', '2025-05-19 09:37:54.686325+00', '{"eTag": "\"4d611c702323d19870173f7ba1d8c477\"", "size": 564550, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-19T09:37:55.000Z", "contentLength": 564550, "httpStatusCode": 200}', 'd4450a27-a116-49c4-8a70-8c903f077235', 'd707eee8-8de6-49fa-a4a6-00d79d6eded8', '{}'),
	('618d29cd-6064-465f-b564-2630dc28f026', 'therapist_profiles', '53c97092-2634-4c47-ad83-808566dfbdcd-1747648762351.jpeg', '53c97092-2634-4c47-ad83-808566dfbdcd', '2025-05-19 09:59:24.817037+00', '2025-05-19 09:59:24.817037+00', '2025-05-19 09:59:24.817037+00', '{"eTag": "\"eee5925129bf33fa4387064e5b68603e\"", "size": 232189, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-19T09:59:25.000Z", "contentLength": 232189, "httpStatusCode": 200}', '6a6e7f99-b0c6-465d-afd1-239595baa314', '53c97092-2634-4c47-ad83-808566dfbdcd', '{}'),
	('a5caa531-6a9b-4da2-814d-d809d51b9e61', 'therapist_profiles', 'a6f658f8-149d-4063-b1d9-c54105f03392-1747650097836.jpg', 'a6f658f8-149d-4063-b1d9-c54105f03392', '2025-05-19 10:21:38.946825+00', '2025-05-19 10:21:38.946825+00', '2025-05-19 10:21:38.946825+00', '{"eTag": "\"a1df929eca80288fab0b7a572ca223dd\"", "size": 83448, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-19T10:21:39.000Z", "contentLength": 83448, "httpStatusCode": 200}', 'cf98f85b-0d83-4e11-8560-fdc0709ff9b3', 'a6f658f8-149d-4063-b1d9-c54105f03392', '{}'),
	('ebeff4c7-0fad-4388-871e-5fa71adfee6b', 'therapists.verification.documents', '4b6f4102-c588-406c-a091-79dd2485fb81/id/id_4b6f4102-c588-406c-a091-79dd2485fb81_1747652647587.jpeg', '4b6f4102-c588-406c-a091-79dd2485fb81', '2025-05-19 11:04:08.219763+00', '2025-05-19 11:04:08.219763+00', '2025-05-19 11:04:08.219763+00', '{"eTag": "\"855c48981e726f2c3423fb33202b98b8\"", "size": 174063, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-19T11:04:09.000Z", "contentLength": 174063, "httpStatusCode": 200}', 'c855d6b3-9292-476b-9a1d-097f0a05bbb5', '4b6f4102-c588-406c-a091-79dd2485fb81', '{}'),
	('6eb4c8f4-bbb0-480a-abf4-10ff8ac2623e', 'therapists.verification.documents', '4b6f4102-c588-406c-a091-79dd2485fb81/certificates/cert_4b6f4102-c588-406c-a091-79dd2485fb81_1747652648203_30b452f9-1e3a-449a-aae1-174115b5f61a.JPG', '4b6f4102-c588-406c-a091-79dd2485fb81', '2025-05-19 11:04:08.495483+00', '2025-05-19 11:04:08.495483+00', '2025-05-19 11:04:08.495483+00', '{"eTag": "\"af6c60cca7f453bf107a72f4840b462a\"", "size": 126501, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-19T11:04:09.000Z", "contentLength": 126501, "httpStatusCode": 200}', '6c27bee9-5fa7-4599-9132-dda68af15382', '4b6f4102-c588-406c-a091-79dd2485fb81', '{}'),
	('4b52ac5c-a97c-4dad-b721-2fab403975de', 'therapist_profiles', 'e9af8519-44db-48ee-9e9d-b7fe14ccc7a5-1747829121312.jpeg', 'e9af8519-44db-48ee-9e9d-b7fe14ccc7a5', '2025-05-21 12:05:22.319885+00', '2025-05-21 12:05:22.319885+00', '2025-05-21 12:05:22.319885+00', '{"eTag": "\"a978a56338fa2dbd71cf14d10f17aaf8\"", "size": 3406907, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-21T12:05:23.000Z", "contentLength": 3406907, "httpStatusCode": 200}', 'c92826d3-e58a-4315-895b-0bbb22eba424', 'e9af8519-44db-48ee-9e9d-b7fe14ccc7a5', '{}'),
	('8b5e89db-2b88-43c3-8f29-cfd12ef1cf0a', 'therapist_profiles', 'feea398b-e2c0-4217-be62-0da00ee5ac3b-1747657123699.jpg', 'feea398b-e2c0-4217-be62-0da00ee5ac3b', '2025-05-19 12:18:44.40574+00', '2025-05-19 12:18:44.40574+00', '2025-05-19 12:18:44.40574+00', '{"eTag": "\"4cf13d5f2edd043c2a5f12c8ef09a4d5\"", "size": 50414, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-19T12:18:45.000Z", "contentLength": 50414, "httpStatusCode": 200}', '6652bb88-297f-48bb-aed0-6709df46970d', 'feea398b-e2c0-4217-be62-0da00ee5ac3b', '{}'),
	('c6d7497b-a851-4881-b42d-a6c423d3a07d', 'therapist_profiles', '8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8-1747666869462.jpg', '8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8', '2025-05-19 15:01:10.576106+00', '2025-05-19 15:01:10.576106+00', '2025-05-19 15:01:10.576106+00', '{"eTag": "\"71eea75153b89a889c807540f6a415e6\"", "size": 176133, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-19T15:01:11.000Z", "contentLength": 176133, "httpStatusCode": 200}', '64389ad9-f505-4ee6-a663-35d1fd1a1271', '8c38db4c-fdc3-44fb-8a65-6cc1b5c3bdc8', '{}'),
	('46775445-e75a-48b8-89b2-3c0085befb9e', 'therapists.verification.documents', '65da1664-c0da-4c49-88c8-dce05acc1374/id/id_65da1664-c0da-4c49-88c8-dce05acc1374_1747905470425.jpg', '65da1664-c0da-4c49-88c8-dce05acc1374', '2025-05-22 09:17:51.157967+00', '2025-05-22 09:17:51.157967+00', '2025-05-22 09:17:51.157967+00', '{"eTag": "\"41cfaf9b7be97ac50a98464dbd3c9683\"", "size": 189053, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T09:17:52.000Z", "contentLength": 189053, "httpStatusCode": 200}', 'c4617421-a221-41f3-8bcf-5a45c9f8faad', '65da1664-c0da-4c49-88c8-dce05acc1374', '{}'),
	('37d67e6a-305b-4505-9f02-35c4f821c417', 'therapist_profiles', 'dd8d0335-6696-4fb6-b186-31a0533d9587-1747668772285.jpeg', 'dd8d0335-6696-4fb6-b186-31a0533d9587', '2025-05-19 15:32:52.84358+00', '2025-05-19 15:32:52.84358+00', '2025-05-19 15:32:52.84358+00', '{"eTag": "\"6c93c9500f15e303554a3f657ddd1935\"", "size": 130934, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-19T15:32:53.000Z", "contentLength": 130934, "httpStatusCode": 200}', '0036e0b5-c58f-4047-9147-ebd2dc1dda43', 'dd8d0335-6696-4fb6-b186-31a0533d9587', '{}'),
	('affd7b41-df93-4153-866e-3e32588a8d3c', 'therapist_profiles', 'd3275dfe-f4df-44fc-acaa-659e92369e66-1747723604426.JPG', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '2025-05-20 06:46:44.860209+00', '2025-05-20 06:46:44.860209+00', '2025-05-20 06:46:44.860209+00', '{"eTag": "\"10e880d21982a2c1e05578fc29613da9\"", "size": 145546, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-20T06:46:45.000Z", "contentLength": 145546, "httpStatusCode": 200}', 'e9c1f1d5-530b-4861-b0a0-eb0572ede67d', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '{}'),
	('c10662f4-689c-42fa-9c8b-1c379638442b', 'therapist_profiles', '622d14e0-2b33-4c8b-81d5-231a707fd100-1747729699398.jpg', '622d14e0-2b33-4c8b-81d5-231a707fd100', '2025-05-20 08:28:20.72508+00', '2025-05-20 08:28:20.72508+00', '2025-05-20 08:28:20.72508+00', '{"eTag": "\"71e8edd20ef4071900acfd31d556804a\"", "size": 1099489, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-20T08:28:21.000Z", "contentLength": 1099489, "httpStatusCode": 200}', '86068e53-b131-485b-a78c-b980c85086f8', '622d14e0-2b33-4c8b-81d5-231a707fd100', '{}'),
	('f3daf526-f86f-4853-be4d-6c7637e8c90a', 'therapist_profiles', '072aa24d-bfc3-4b0c-93f2-1435906d8381-1747732345377.jpeg', '072aa24d-bfc3-4b0c-93f2-1435906d8381', '2025-05-20 09:12:25.894124+00', '2025-05-20 09:12:25.894124+00', '2025-05-20 09:12:25.894124+00', '{"eTag": "\"9bb8443b184c39f2e19be76a75c7262c\"", "size": 194872, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-20T09:12:26.000Z", "contentLength": 194872, "httpStatusCode": 200}', '3686e334-e365-4be9-9c36-708a883c3a29', '072aa24d-bfc3-4b0c-93f2-1435906d8381', '{}'),
	('6c010c4b-17d0-4e8b-88d1-deda37d57d3a', 'therapist_profiles', '7b00956b-eafb-4d19-aed0-67dad9ab51ee-1747746287547.jpg', '7b00956b-eafb-4d19-aed0-67dad9ab51ee', '2025-05-20 13:03:37.641458+00', '2025-05-20 13:03:37.641458+00', '2025-05-20 13:03:37.641458+00', '{"eTag": "\"028983b12385e1e5a86f39c9efd4e5d2\"", "size": 777910, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-20T13:03:38.000Z", "contentLength": 777910, "httpStatusCode": 200}', '3368b521-d104-47f1-9f7c-328cf0846d12', '7b00956b-eafb-4d19-aed0-67dad9ab51ee', '{}'),
	('008fdc2c-e0ac-417f-98bf-53f949f76060', 'therapist_profiles', '7f541d24-fa47-444f-9ca4-f4f7bc3f4dde-1747750969031.jpg', '7f541d24-fa47-444f-9ca4-f4f7bc3f4dde', '2025-05-20 14:22:49.565915+00', '2025-05-20 14:22:49.565915+00', '2025-05-20 14:22:49.565915+00', '{"eTag": "\"3a2cf27f415f7c534baf3467b98acbc9\"", "size": 98498, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-20T14:22:50.000Z", "contentLength": 98498, "httpStatusCode": 200}', '1f86655f-8caf-474c-80e8-2f29b08ffea7', '7f541d24-fa47-444f-9ca4-f4f7bc3f4dde', '{}'),
	('c11cd515-1b0b-4ec1-9b6c-af7fc2b3a726', 'therapists.verification.documents', '3a317800-976d-4277-a491-27d7962bb16b/id/id_3a317800-976d-4277-a491-27d7962bb16b_1747841433375.JPG', '3a317800-976d-4277-a491-27d7962bb16b', '2025-05-21 15:30:33.933196+00', '2025-05-21 15:30:33.933196+00', '2025-05-21 15:30:33.933196+00', '{"eTag": "\"af6c60cca7f453bf107a72f4840b462a\"", "size": 126501, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-21T15:30:34.000Z", "contentLength": 126501, "httpStatusCode": 200}', 'adb2a002-900f-42fe-9a1c-18cdb712b71e', '3a317800-976d-4277-a491-27d7962bb16b', '{}'),
	('b631c816-1d82-4972-8fa3-2e9ddd7da710', 'therapists.verification.documents', '3a317800-976d-4277-a491-27d7962bb16b/certificates/cert_3a317800-976d-4277-a491-27d7962bb16b_1747841433981_ChatGPT_Image_14_mai_2025,_10_12_27.png', '3a317800-976d-4277-a491-27d7962bb16b', '2025-05-21 15:30:35.018177+00', '2025-05-21 15:30:35.018177+00', '2025-05-21 15:30:35.018177+00', '{"eTag": "\"d819fe35abf4a8c024d335ec5055854c\"", "size": 2257225, "mimetype": "image/png", "cacheControl": "max-age=3600", "lastModified": "2025-05-21T15:30:35.000Z", "contentLength": 2257225, "httpStatusCode": 200}', '36a10ba4-5783-4230-af43-24695df1f91e', '3a317800-976d-4277-a491-27d7962bb16b', '{}'),
	('e1794358-4048-47d7-a985-e3ff0b80dd08', 'therapists.verification.documents', '65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905471014_Diploma_Formator.pdf', '65da1664-c0da-4c49-88c8-dce05acc1374', '2025-05-22 09:17:51.670477+00', '2025-05-22 09:17:51.670477+00', '2025-05-22 09:17:51.670477+00', '{"eTag": "\"3c4cc67304e0f13c19028566250374ef\"", "size": 146459, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T09:17:52.000Z", "contentLength": 146459, "httpStatusCode": 200}', 'bb27c0b4-04fb-476c-9d07-5d077fb65a17', '65da1664-c0da-4c49-88c8-dce05acc1374', '{}'),
	('0caffbc7-6bf5-409b-ba27-d763a96bcfe5', 'therapists.verification.documents', '65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905471524_Diploma_Grand_Master_5-6.pdf', '65da1664-c0da-4c49-88c8-dce05acc1374', '2025-05-22 09:17:51.926636+00', '2025-05-22 09:17:51.926636+00', '2025-05-22 09:17:51.926636+00', '{"eTag": "\"253b2c6860b68b53a7aae589bf293093\"", "size": 79396, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T09:17:52.000Z", "contentLength": 79396, "httpStatusCode": 200}', 'b4a44056-af59-45c7-8088-735807f235bf', '65da1664-c0da-4c49-88c8-dce05acc1374', '{}'),
	('0c3e1d1d-760b-4d34-a3be-5ce8def67b40', 'therapists.verification.documents', '65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905471777_Diploma_Licenta-_ANAMARIA_BUZATU.pdf', '65da1664-c0da-4c49-88c8-dce05acc1374', '2025-05-22 09:17:52.313982+00', '2025-05-22 09:17:52.313982+00', '2025-05-22 09:17:52.313982+00', '{"eTag": "\"2acd66577141ffda0be5898ea080911f\"", "size": 248492, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T09:17:53.000Z", "contentLength": 248492, "httpStatusCode": 200}', 'bc48bb90-0c1e-4871-95d2-e689f73aeb1d', '65da1664-c0da-4c49-88c8-dce05acc1374', '{}'),
	('4fc600f7-e0db-4e35-8011-52b626e303a1', 'therapists.verification.documents', '65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905472178_Diploma_Reiki_Gendai.pdf', '65da1664-c0da-4c49-88c8-dce05acc1374', '2025-05-22 09:17:52.625233+00', '2025-05-22 09:17:52.625233+00', '2025-05-22 09:17:52.625233+00', '{"eTag": "\"89d6460498bdd20a690fef66f5cf76a4\"", "size": 88761, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T09:17:53.000Z", "contentLength": 88761, "httpStatusCode": 200}', '50d976d8-488d-401f-814a-bfca48d570e6', '65da1664-c0da-4c49-88c8-dce05acc1374', '{}'),
	('181e241f-8353-496c-b7ba-a00dd66ab781', 'therapists.verification.documents', '65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905473507_Dragon_Reiki___Level_2_Certificate!.pdf', '65da1664-c0da-4c49-88c8-dce05acc1374', '2025-05-22 09:17:54.37828+00', '2025-05-22 09:17:54.37828+00', '2025-05-22 09:17:54.37828+00', '{"eTag": "\"3d975652e6f732250c39d5d36bd89958\"", "size": 1007880, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T09:17:55.000Z", "contentLength": 1007880, "httpStatusCode": 200}', '347684d7-cd34-4b0a-ad22-c18a4a54eede', '65da1664-c0da-4c49-88c8-dce05acc1374', '{}'),
	('e6c3090f-c1d5-498c-adf2-c7fc2a0dc45b', 'therapists.verification.documents', '65da1664-c0da-4c49-88c8-dce05acc1374/certificates/cert_65da1664-c0da-4c49-88c8-dce05acc1374_1747905474237_Moon_Reiki_Certificate!.pdf', '65da1664-c0da-4c49-88c8-dce05acc1374', '2025-05-22 09:17:54.841454+00', '2025-05-22 09:17:54.841454+00', '2025-05-22 09:17:54.841454+00', '{"eTag": "\"35e639f53ad88fbe22fc96695d520675\"", "size": 745752, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T09:17:55.000Z", "contentLength": 745752, "httpStatusCode": 200}', '858d27aa-b460-4469-bae7-e4a2ce221468', '65da1664-c0da-4c49-88c8-dce05acc1374', '{}'),
	('a30d6eb3-6129-46b3-b547-9547eaa24774', 'therapist_profiles', '1f149689-c4dc-412f-8de6-9b25ee804842-1747918722238.jpg', '1f149689-c4dc-412f-8de6-9b25ee804842', '2025-05-22 12:58:43.324598+00', '2025-05-22 12:58:43.324598+00', '2025-05-22 12:58:43.324598+00', '{"eTag": "\"d852b4943187b9b65a235f6fa84f6b75\"", "size": 497811, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T12:58:44.000Z", "contentLength": 497811, "httpStatusCode": 200}', '704ae623-8e82-47b7-90c1-62d2f54db74c', '1f149689-c4dc-412f-8de6-9b25ee804842', '{}'),
	('17f0672d-e4e0-4592-a7c9-6a32e9a16aaa', 'therapist_profiles', '1f149689-c4dc-412f-8de6-9b25ee804842-1747919323758.jpg', '1f149689-c4dc-412f-8de6-9b25ee804842', '2025-05-22 13:08:44.966378+00', '2025-05-22 13:08:44.966378+00', '2025-05-22 13:08:44.966378+00', '{"eTag": "\"060e43d5c408927a093c7d16b7f22bf5\"", "size": 290859, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T13:08:45.000Z", "contentLength": 290859, "httpStatusCode": 200}', '86ccb8ef-78fd-440f-94dc-0896402d2f51', '1f149689-c4dc-412f-8de6-9b25ee804842', '{}'),
	('f2498a25-f090-4d70-b22e-c518dbe4cde4', 'therapist_profiles', '1bd491bf-3874-47d1-a4ed-0983f63a866e-1747920559712.jpg', '1bd491bf-3874-47d1-a4ed-0983f63a866e', '2025-05-22 13:30:34.670059+00', '2025-05-22 13:30:34.670059+00', '2025-05-22 13:30:34.670059+00', '{"eTag": "\"b58527ab9d7e319136766465fa7b7cea\"", "size": 375571, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T13:30:35.000Z", "contentLength": 375571, "httpStatusCode": 200}', 'cacbee88-81e7-4ede-b89a-1c6824b5ec98', '1bd491bf-3874-47d1-a4ed-0983f63a866e', '{}'),
	('ed5cb0cd-5af9-48e3-a434-397e3bd1d696', 'therapist_profiles', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f-1747926302398.jpeg', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', '2025-05-22 15:05:00.554085+00', '2025-05-22 15:05:00.554085+00', '2025-05-22 15:05:00.554085+00', '{"eTag": "\"186f31ef094a8f764094eed3824a2154\"", "size": 265292, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T15:05:01.000Z", "contentLength": 265292, "httpStatusCode": 200}', '2535e11f-d15f-4842-8a0f-2a1506a6a1c0', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', '{}'),
	('314f8bc3-1205-449e-b20d-0eb9c838a770', 'therapists.verification.documents', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f/id/id_8458bab3-1fb1-4eb7-8cad-f555bc58fc8f_1747926494565.pdf', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', '2025-05-22 15:08:12.933135+00', '2025-05-22 15:08:12.933135+00', '2025-05-22 15:08:12.933135+00', '{"eTag": "\"9e06c526120f86b8ac7ae51822640c5b\"", "size": 259850, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T15:08:13.000Z", "contentLength": 259850, "httpStatusCode": 200}', '63a9b3d1-2c65-4def-bab6-88db546366c0', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', '{}'),
	('7b2fa3de-c3b7-45c5-9902-9b4322a4e6e2', 'therapists.verification.documents', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f/certificates/cert_8458bab3-1fb1-4eb7-8cad-f555bc58fc8f_1747926495370_Sandu_Elena_-_atestat_psihoterapie.pdf', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', '2025-05-22 15:08:13.914404+00', '2025-05-22 15:08:13.914404+00', '2025-05-22 15:08:13.914404+00', '{"eTag": "\"8d9dd02effb80044511985ef717c5f2b\"", "size": 1533805, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T15:08:14.000Z", "contentLength": 1533805, "httpStatusCode": 200}', '84b3e21e-e341-4f2c-b3f3-861c11c52319', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', '{}'),
	('f8867665-9047-4089-bebc-8fc95631451c', 'therapists.verification.documents', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f/certificates/cert_8458bab3-1fb1-4eb7-8cad-f555bc58fc8f_1747926496523_Sandu_Elena_clinica_autonom.pdf', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', '2025-05-22 15:08:14.949158+00', '2025-05-22 15:08:14.949158+00', '2025-05-22 15:08:14.949158+00', '{"eTag": "\"109a690d6b60a952bc60d77af14ca85b\"", "size": 1535471, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T15:08:15.000Z", "contentLength": 1535471, "httpStatusCode": 200}', 'faeb94f4-1d77-40bb-9e4b-4bd3a11ddb76', '8458bab3-1fb1-4eb7-8cad-f555bc58fc8f', '{}'),
	('a23642f2-d2c6-43b8-8b8f-5efa7b4a839c', 'therapist_profiles', 'de7ba501-a94e-4f86-81b3-0afe662ae8de-1747926761111.jpg', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '2025-05-22 15:12:41.528716+00', '2025-05-22 15:12:41.528716+00', '2025-05-22 15:12:41.528716+00', '{"eTag": "\"75a2fff6504facfc7760b394e20b75b5\"", "size": 45583, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T15:12:42.000Z", "contentLength": 45583, "httpStatusCode": 200}', '55cb0558-bcbf-41d4-b8ea-0f03a2489073', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '{}'),
	('66c7fd51-7a33-47f2-b0b3-1b33a2dcb15b', 'therapists.verification.documents', 'de7ba501-a94e-4f86-81b3-0afe662ae8de/id/id_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930307418.pdf', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '2025-05-22 16:11:48.109014+00', '2025-05-22 16:11:48.109014+00', '2025-05-22 16:11:48.109014+00', '{"eTag": "\"51e6b5ea0728f76cb09f4d12377a2b46\"", "size": 489989, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T16:11:48.000Z", "contentLength": 489989, "httpStatusCode": 200}', '80844920-31b8-4886-889a-d89b0bc0ef91', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '{}'),
	('31a5ae72-7002-444f-aa31-f99f3afab5d8', 'therapists.verification.documents', 'de7ba501-a94e-4f86-81b3-0afe662ae8de/certificates/cert_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930308169_Coaching_Constellations_-_1to1_-_Dan_Magirescu_(03.2023).pdf', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '2025-05-22 16:11:48.943461+00', '2025-05-22 16:11:48.943461+00', '2025-05-22 16:11:48.943461+00', '{"eTag": "\"01806ad00bf9edc82ce4d5d9770c676a\"", "size": 3623652, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T16:11:49.000Z", "contentLength": 3623652, "httpStatusCode": 200}', 'f0f82f36-11df-4a14-b3ce-2d1049d1a4f4', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '{}'),
	('0bcfa6c9-2e67-4fbd-8008-a9140e41fe00', 'therapists.verification.documents', 'de7ba501-a94e-4f86-81b3-0afe662ae8de/certificates/cert_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930308992_Coaching_Constellations_-_Fundamentals_I_-_Dan_Magirescu_(02.2023).pdf', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '2025-05-22 16:11:49.209861+00', '2025-05-22 16:11:49.209861+00', '2025-05-22 16:11:49.209861+00', '{"eTag": "\"2c661020f53120d9b5f237ea5bf8af1c\"", "size": 406645, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T16:11:50.000Z", "contentLength": 406645, "httpStatusCode": 200}', '97b4a50d-cc0d-4638-912e-30cc85cb8229', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '{}'),
	('f219e35c-19ab-4001-8cc3-c0e36c797ed9', 'therapists.verification.documents', 'de7ba501-a94e-4f86-81b3-0afe662ae8de/certificates/cert_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930309262_Coaching_Constellations_-_Fundamentals_II_-_Dan_Magirescu_(06.2023).pdf', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '2025-05-22 16:11:49.503817+00', '2025-05-22 16:11:49.503817+00', '2025-05-22 16:11:49.503817+00', '{"eTag": "\"04e1a980b0238313bb5a2c54fa7c6ce4\"", "size": 428807, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T16:11:50.000Z", "contentLength": 428807, "httpStatusCode": 200}', 'c703132b-b0ed-42c0-8fde-4994f8980e6e', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '{}'),
	('0b18d50a-af03-4300-a5f8-11b38f988e51', 'therapists.verification.documents', 'de7ba501-a94e-4f86-81b3-0afe662ae8de/certificates/cert_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930309561_Coaching_Constellations_-_Fundamentals_III_-_Dan_Magirescu_(11.2023).pdf', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '2025-05-22 16:11:49.972742+00', '2025-05-22 16:11:49.972742+00', '2025-05-22 16:11:49.972742+00', '{"eTag": "\"176b1e42e05ece0e53c8ff182349d30d\"", "size": 1417182, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T16:11:50.000Z", "contentLength": 1417182, "httpStatusCode": 200}', 'aadb65f8-6ca7-47e3-b1f8-721930d8a7e3', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '{}'),
	('22872ee3-2711-4f0e-b786-eab373781a33', 'therapists.verification.documents', 'de7ba501-a94e-4f86-81b3-0afe662ae8de/certificates/cert_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930310030_Coaching_Constellations_-_Somatic_-_Dan_Magirescu_(10.2023).pdf', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '2025-05-22 16:11:50.527454+00', '2025-05-22 16:11:50.527454+00', '2025-05-22 16:11:50.527454+00', '{"eTag": "\"335f7b68684e8c7435e2a08505909907\"", "size": 394352, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T16:11:51.000Z", "contentLength": 394352, "httpStatusCode": 200}', '59b25874-9cd4-46c1-ab83-966667b81a74', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '{}'),
	('7da31835-d9b9-40cc-97c8-338509e86a87', 'therapists.verification.documents', 'de7ba501-a94e-4f86-81b3-0afe662ae8de/certificates/cert_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930310582_Coaching_Constellations_-_Team_Coaching_-_Dan_Magirescu_(11.2023).pdf', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '2025-05-22 16:11:50.874499+00', '2025-05-22 16:11:50.874499+00', '2025-05-22 16:11:50.874499+00', '{"eTag": "\"c33de8b9df13526d6798bcaf7839d39a\"", "size": 328440, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T16:11:51.000Z", "contentLength": 328440, "httpStatusCode": 200}', 'b595ef22-97e2-41a4-9fcd-9b08f2cecb35', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '{}'),
	('6ad42993-2db7-4fab-ac63-dee5633b29b8', 'therapists.verification.documents', 'de7ba501-a94e-4f86-81b3-0afe662ae8de/certificates/cert_de7ba501-a94e-4f86-81b3-0afe662ae8de_1747930310979_One2Coach_-_Certificat_ACSTH__Dan_Magirescu_(10.2021).pdf', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '2025-05-22 16:11:51.148212+00', '2025-05-22 16:11:51.148212+00', '2025-05-22 16:11:51.148212+00', '{"eTag": "\"08b0c17346249d9f1bb052f5fbd141f2\"", "size": 79835, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T16:11:52.000Z", "contentLength": 79835, "httpStatusCode": 200}', '0d42a302-0b9d-4b79-a38b-062e31ac5da8', 'de7ba501-a94e-4f86-81b3-0afe662ae8de', '{}'),
	('eaffb93c-f53f-41f2-bb64-1627a5864b72', 'therapists.verification.documents', '1e8e19fd-7346-4d83-807e-404c01903baf/id/id_1e8e19fd-7346-4d83-807e-404c01903baf_1747952204930.jpg', '1e8e19fd-7346-4d83-807e-404c01903baf', '2025-05-22 22:16:44.79915+00', '2025-05-22 22:16:44.79915+00', '2025-05-22 22:16:44.79915+00', '{"eTag": "\"e27596d92fbba5377ab7ef21d659b158\"", "size": 1437893, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T22:16:45.000Z", "contentLength": 1437893, "httpStatusCode": 200}', 'd256e2ab-3ebb-43a0-b378-e805058363e1', '1e8e19fd-7346-4d83-807e-404c01903baf', '{}'),
	('0d149ce4-4f82-4b43-b755-a999487be28c', 'therapists.verification.documents', '1e8e19fd-7346-4d83-807e-404c01903baf/certificates/cert_1e8e19fd-7346-4d83-807e-404c01903baf_1747952205854_hero-image.jpg', '1e8e19fd-7346-4d83-807e-404c01903baf', '2025-05-22 22:16:45.610402+00', '2025-05-22 22:16:45.610402+00', '2025-05-22 22:16:45.610402+00', '{"eTag": "\"e27596d92fbba5377ab7ef21d659b158\"", "size": 1437893, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-22T22:16:46.000Z", "contentLength": 1437893, "httpStatusCode": 200}', 'd4ffc8d4-7784-4f47-99cb-19a23da016c2', '1e8e19fd-7346-4d83-807e-404c01903baf', '{}'),
	('4f0c54cd-3f96-4a77-80d0-8ef5cb3f18f6', 'therapists.verification.documents', 'd3275dfe-f4df-44fc-acaa-659e92369e66/id/id_d3275dfe-f4df-44fc-acaa-659e92369e66_1747984615573.pdf', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '2025-05-23 07:16:57.075376+00', '2025-05-23 07:16:57.075376+00', '2025-05-23 07:16:57.075376+00', '{"eTag": "\"7074c683933376a557c7a01003cd44a5\"", "size": 106421, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-23T07:16:58.000Z", "contentLength": 106421, "httpStatusCode": 200}', '2c6125b5-421e-4af3-91d6-86eb31e86765', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '{}'),
	('1414e2f6-4f0e-488c-b6e8-d34b1ff3f606', 'therapists.verification.documents', 'd3275dfe-f4df-44fc-acaa-659e92369e66/id/id_d3275dfe-f4df-44fc-acaa-659e92369e66_1747984637379.pdf', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '2025-05-23 07:17:18.430784+00', '2025-05-23 07:17:18.430784+00', '2025-05-23 07:17:18.430784+00', '{"eTag": "\"7074c683933376a557c7a01003cd44a5\"", "size": 106421, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-23T07:17:19.000Z", "contentLength": 106421, "httpStatusCode": 200}', 'da086e5c-3775-45cb-be1d-b7946e500417', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '{}'),
	('bcbe5205-ce49-4fad-bbdd-278dd98e0d34', 'therapists.verification.documents', 'd3275dfe-f4df-44fc-acaa-659e92369e66/id/id_d3275dfe-f4df-44fc-acaa-659e92369e66_1747984660131.pdf', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '2025-05-23 07:17:41.143925+00', '2025-05-23 07:17:41.143925+00', '2025-05-23 07:17:41.143925+00', '{"eTag": "\"7074c683933376a557c7a01003cd44a5\"", "size": 106421, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-23T07:17:42.000Z", "contentLength": 106421, "httpStatusCode": 200}', '0494608f-fa59-454c-a1e1-a7fb286f81d4', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '{}'),
	('7e4fa4a2-4678-4c36-8cd5-ae33ba88182d', 'therapist_profiles', 'd3275dfe-f4df-44fc-acaa-659e92369e66-1747984702890.jpg', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '2025-05-23 07:18:24.10678+00', '2025-05-23 07:18:24.10678+00', '2025-05-23 07:18:24.10678+00', '{"eTag": "\"09fd064322885d6b7442644068a0dc95\"", "size": 236049, "mimetype": "image/jpeg", "cacheControl": "max-age=3600", "lastModified": "2025-05-23T07:18:24.000Z", "contentLength": 236049, "httpStatusCode": 200}', 'dd7a0f78-4e16-4625-9883-3016f187b9ba', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '{}'),
	('60f90a79-7992-49f0-80d3-0d506752b51d', 'therapists.verification.documents', 'd3275dfe-f4df-44fc-acaa-659e92369e66/id/id_d3275dfe-f4df-44fc-acaa-659e92369e66_1747984802036.pdf', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '2025-05-23 07:20:03.410507+00', '2025-05-23 07:20:03.410507+00', '2025-05-23 07:20:03.410507+00', '{"eTag": "\"7074c683933376a557c7a01003cd44a5\"", "size": 106421, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-23T07:20:04.000Z", "contentLength": 106421, "httpStatusCode": 200}', '3bdcaa17-7d77-482e-a19f-040fcd73a750', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '{}'),
	('768c5cb0-7ba0-4d78-a085-926f7a646283', 'therapists.verification.documents', 'd3275dfe-f4df-44fc-acaa-659e92369e66/certificates/cert_d3275dfe-f4df-44fc-acaa-659e92369e66_1747984802691_36.Dosar_Jilavu_Danut_Atestat_Psihologie_Clinica.pdf', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '2025-05-23 07:20:04.331569+00', '2025-05-23 07:20:04.331569+00', '2025-05-23 07:20:04.331569+00', '{"eTag": "\"f5dcfbd44c87bc0085d1c99504952696\"", "size": 1262346, "mimetype": "application/pdf", "cacheControl": "max-age=3600", "lastModified": "2025-05-23T07:20:05.000Z", "contentLength": 1262346, "httpStatusCode": 200}', '9bf23078-df3a-40d1-a489-9bce459d818c', 'd3275dfe-f4df-44fc-acaa-659e92369e66', '{}');


--
-- Data for Name: s3_multipart_uploads; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--



--
-- Data for Name: s3_multipart_uploads_parts; Type: TABLE DATA; Schema: storage; Owner: supabase_storage_admin
--



--
-- Name: refresh_tokens_id_seq; Type: SEQUENCE SET; Schema: auth; Owner: supabase_auth_admin
--

SELECT pg_catalog.setval('"auth"."refresh_tokens_id_seq"', 571, true);


--
-- PostgreSQL database dump complete
--

RESET ALL;
