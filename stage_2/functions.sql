-- 1. Расстояние между двумя точками на Земле в километрах
CREATE OR REPLACE FUNCTION distance_km(
   arg_lat1 NUMERIC, arg_lon1 NUMERIC,
   arg_lat2 NUMERIC, arg_lon2 NUMERIC)
RETURNS NUMERIC AS $$
DECLARE
   dlat DOUBLE PRECISION := radians(arg_lat2 - arg_lat1);
   dlon DOUBLE PRECISION := radians(arg_lon2 - arg_lon1);
   a DOUBLE PRECISION;
BEGIN
   IF arg_lat1 IS NULL OR arg_lat2 IS NULL THEN
       RETURN NULL;
   END IF;
   a := sin(dlat / 2) ^ 2
      + cos(radians(arg_lat1)) * cos(radians(arg_lat2)) * sin(dlon / 2) ^ 2;
   RETURN round((2 * 6371 * asin(sqrt(a)))::NUMERIC, 1);
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- 2. Создание уведомления (при привязанном Telegram ставится в очередь на отправку)
CREATE OR REPLACE FUNCTION create_notification(
   arg_user_id BIGINT, arg_type VARCHAR, arg_title VARCHAR, arg_text TEXT)
RETURNS BIGINT AS $$
DECLARE
   new_id BIGINT;
BEGIN
   INSERT INTO notification (user_id, type, title, text, telegram_status)
   SELECT arg_user_id, arg_type, arg_title, arg_text,
          CASE WHEN telegram_id IS NOT NULL THEN 'PENDING' END
   FROM users WHERE id = arg_user_id
   RETURNING id INTO new_id;
   RETURN new_id;
END;
$$ LANGUAGE plpgsql;


-- 3. Регистрация пользователя: учётная запись, токен подтверждения email и запись в журнале
CREATE OR REPLACE FUNCTION register_user(
   arg_email VARCHAR, arg_password_hash VARCHAR, arg_verify_token_hash VARCHAR)
RETURNS BIGINT AS $$
DECLARE
   new_user_id BIGINT;
BEGIN
   BEGIN
       INSERT INTO users (email, password_hash)
       VALUES (arg_email, arg_password_hash)
       RETURNING id INTO new_user_id;
   EXCEPTION WHEN unique_violation THEN
       RAISE EXCEPTION 'Пользователь с таким Email уже существует';
   END;

   INSERT INTO auth_token (user_id, type, token_hash, expires_at)
   VALUES (new_user_id, 'EMAIL_VERIFY', arg_verify_token_hash, now() + INTERVAL '24 hours');

   INSERT INTO journal (user_id, action, entity_type, entity_id)
   VALUES (new_user_id, 'USER_REGISTERED', 'users', new_user_id);

   RETURN new_user_id;
END;
$$ LANGUAGE plpgsql;


-- 4. Персональная лента рекомендаций с фильтрами и показателем соответствия
CREATE OR REPLACE FUNCTION get_recommendations(
   arg_user_id BIGINT,
   arg_limit INT DEFAULT 20,
   arg_offset INT DEFAULT 0,
   arg_min_age INT DEFAULT NULL,
   arg_max_age INT DEFAULT NULL,
   arg_city VARCHAR DEFAULT NULL,
   arg_max_distance_km NUMERIC DEFAULT NULL,
   arg_interest_ids BIGINT[] DEFAULT NULL)
RETURNS TABLE (
   profile_id BIGINT, user_id BIGINT, name VARCHAR, age INT, city VARCHAR,
   main_photo_url VARCHAR, distance_km NUMERIC, score INT
) AS $$
#variable_conflict use_column
DECLARE
   me profile%ROWTYPE;
   my_loc location%ROWTYPE;
BEGIN
   SELECT * INTO me FROM profile WHERE profile.user_id = arg_user_id;
   IF NOT FOUND THEN
       RAISE EXCEPTION 'У пользователя нет анкеты';
   END IF;
   SELECT * INTO my_loc FROM location WHERE location.profile_id = me.id;

   RETURN QUERY
   WITH liked_interests AS (
       SELECT pi.interest_id, COUNT(*) AS cnt
       FROM reaction r
       JOIN profile_interest pi ON pi.profile_id = r.to_profile_id
       WHERE r.from_user_id = arg_user_id AND r.type = 'LIKE'
       GROUP BY pi.interest_id
   ),
   candidates AS (
       SELECT p.*,
              date_part('year', age(p.birth_date))::INT AS p_age,
              distance_km(my_loc.latitude, my_loc.longitude, l.latitude, l.longitude) AS dist
       FROM profile p
       JOIN users u ON u.id = p.user_id
       LEFT JOIN location l ON l.profile_id = p.id
       WHERE p.user_id <> arg_user_id
         AND u.status = 'ACTIVE'
         AND u.role = 'USER'
         AND (me.looking_for = 'ANY' OR p.gender = me.looking_for)
         AND (p.looking_for = 'ANY' OR p.looking_for = me.gender)
         AND NOT EXISTS (SELECT 1 FROM reaction r
                         WHERE r.from_user_id = arg_user_id AND r.to_profile_id = p.id)
         AND NOT EXISTS (SELECT 1 FROM match m
                         WHERE m.user1_id = LEAST(arg_user_id, p.user_id)
                           AND m.user2_id = GREATEST(arg_user_id, p.user_id))
         AND NOT is_blocked_between(arg_user_id, p.user_id)
         AND NOT has_active_restriction(p.user_id, ARRAY['BAN', 'HIDE_PROFILE'])
   )
   SELECT c.id, c.user_id, c.name, c.p_age, c.city,
          (SELECT ph.url FROM photo ph
           WHERE ph.profile_id = c.id AND ph.is_main AND ph.moderation_status <> 'HIDDEN'),
          c.dist,
          (3 * (SELECT COUNT(*) FROM profile_interest a
                JOIN profile_interest b ON b.interest_id = a.interest_id
                WHERE a.profile_id = me.id AND b.profile_id = c.id)
           + COALESCE((SELECT SUM(li.cnt) FROM liked_interests li
                       JOIN profile_interest b ON b.interest_id = li.interest_id
                       WHERE b.profile_id = c.id), 0)
           + CASE WHEN c.city = me.city THEN 2 ELSE 0 END)::INT AS score
   FROM candidates c
   WHERE (arg_min_age IS NULL OR c.p_age >= arg_min_age)
     AND (arg_max_age IS NULL OR c.p_age <= arg_max_age)
     AND (arg_city IS NULL OR c.city = arg_city)
     AND (arg_max_distance_km IS NULL OR c.dist <= arg_max_distance_km)
     AND (arg_interest_ids IS NULL OR EXISTS (
             SELECT 1 FROM profile_interest b
             WHERE b.profile_id = c.id AND b.interest_id = ANY (arg_interest_ids)))
   ORDER BY score DESC, c.dist NULLS LAST, c.id
   LIMIT arg_limit OFFSET arg_offset;
END;
$$ LANGUAGE plpgsql;


-- 5. Оценка анкеты; при взаимной симпатии уведомляет обоих пользователей
CREATE OR REPLACE FUNCTION react_to_profile(
   arg_user_id BIGINT, arg_profile_id BIGINT, arg_type VARCHAR)
RETURNS BIGINT AS $$
DECLARE
   target_user_id BIGINT;
   had_match BOOLEAN;
   new_match_id BIGINT;
BEGIN
   SELECT user_id INTO target_user_id FROM profile WHERE id = arg_profile_id;
   IF target_user_id IS NULL THEN
       RAISE EXCEPTION 'Анкета не найдена';
   END IF;

   PERFORM pg_advisory_xact_lock(hashtextextended(
       LEAST(arg_user_id, target_user_id)::TEXT || ':'
       || GREATEST(arg_user_id, target_user_id)::TEXT, 0));

   SELECT EXISTS (SELECT 1 FROM match
                  WHERE user1_id = LEAST(arg_user_id, target_user_id)
                    AND user2_id = GREATEST(arg_user_id, target_user_id))
   INTO had_match;

   BEGIN
       INSERT INTO reaction (from_user_id, to_profile_id, type)
       VALUES (arg_user_id, arg_profile_id, arg_type);
   EXCEPTION WHEN unique_violation THEN
       RAISE EXCEPTION 'Вы уже оценили эту анкету';
   END;

   INSERT INTO journal (user_id, action, entity_type, entity_id, details)
   VALUES (arg_user_id, 'PROFILE_RATED', 'profile', arg_profile_id,
           jsonb_build_object('type', arg_type));

   IF had_match THEN
       RETURN NULL;
   END IF;

   SELECT id INTO new_match_id FROM match
   WHERE user1_id = LEAST(arg_user_id, target_user_id)
     AND user2_id = GREATEST(arg_user_id, target_user_id);

   IF new_match_id IS NOT NULL THEN
       PERFORM create_notification(arg_user_id, 'MATCH', 'Новое совпадение',
           'У вас взаимная симпатия с ' || (SELECT name FROM profile WHERE id = arg_profile_id));
       PERFORM create_notification(target_user_id, 'MATCH', 'Новое совпадение',
           'У вас взаимная симпатия с ' || (SELECT name FROM profile WHERE user_id = arg_user_id));
   END IF;
   RETURN new_match_id;
END;
$$ LANGUAGE plpgsql;


-- 6. Отправка сообщения с проверкой ограничений и уведомлением получателя
CREATE OR REPLACE FUNCTION send_message(arg_dialog_id BIGINT, arg_sender_id BIGINT, arg_text TEXT)
RETURNS BIGINT AS $$
DECLARE
   new_id BIGINT;
   recipient_id BIGINT;
   r restriction%ROWTYPE;
BEGIN
   SELECT * INTO r FROM restriction
   WHERE user_id = arg_sender_id
     AND type IN ('BAN', 'NO_MESSAGES')
     AND (expires_at IS NULL OR expires_at > now())
   ORDER BY expires_at DESC NULLS FIRST
   LIMIT 1;
   IF FOUND THEN
       RAISE EXCEPTION 'Отправка сообщений ограничена. Причина: %. %', r.reason,
           CASE WHEN r.expires_at IS NULL THEN 'Ограничение бессрочное'
                ELSE 'Действует до ' || to_char(r.expires_at, 'DD.MM.YYYY HH24:MI') END;
   END IF;

   INSERT INTO message (dialog_id, sender_id, text)
   VALUES (arg_dialog_id, arg_sender_id, arg_text)
   RETURNING id INTO new_id;

   SELECT CASE WHEN m.user1_id = arg_sender_id THEN m.user2_id ELSE m.user1_id END
   INTO recipient_id
   FROM dialog d JOIN match m ON m.id = d.match_id
   WHERE d.id = arg_dialog_id;

   PERFORM create_notification(recipient_id, 'MESSAGE', 'Новое сообщение',
       (SELECT name FROM profile WHERE user_id = arg_sender_id) || ': ' || left(arg_text, 100));
   RETURN new_id;
END;
$$ LANGUAGE plpgsql;


-- 7. Применение санкций по жалобе: ограничение, скрытие контента, принятие жалобы, уведомление
CREATE OR REPLACE FUNCTION apply_sanction(
   arg_complaint_id BIGINT,
   arg_moderator_id BIGINT,
   arg_restriction_type VARCHAR,
   arg_reason TEXT,
   arg_expires_at TIMESTAMPTZ DEFAULT NULL,
   arg_hide_message BOOLEAN DEFAULT FALSE,
   arg_hide_photo_ids BIGINT[] DEFAULT NULL)
RETURNS BIGINT AS $$
DECLARE
   c complaint%ROWTYPE;
   new_restriction_id BIGINT;
BEGIN
   SELECT * INTO c FROM complaint WHERE id = arg_complaint_id FOR UPDATE;
   IF NOT FOUND THEN
       RAISE EXCEPTION 'Жалоба не найдена';
   END IF;
   IF c.status IN ('REJECTED', 'ACCEPTED') THEN
       RAISE EXCEPTION 'Жалоба уже рассмотрена';
   END IF;

   IF arg_restriction_type IS NOT NULL THEN
       INSERT INTO restriction (user_id, type, reason, complaint_id, created_by, expires_at)
       VALUES (c.target_user_id, arg_restriction_type, arg_reason,
               arg_complaint_id, arg_moderator_id, arg_expires_at)
       RETURNING id INTO new_restriction_id;
   END IF;

   IF arg_hide_message AND c.message_id IS NOT NULL THEN
       UPDATE message SET status = 'HIDDEN' WHERE id = c.message_id;
   END IF;

   IF arg_hide_photo_ids IS NOT NULL THEN
       UPDATE photo SET moderation_status = 'HIDDEN', is_main = FALSE
       WHERE id = ANY (arg_hide_photo_ids)
         AND profile_id IN (SELECT id FROM profile WHERE user_id = c.target_user_id);
   END IF;

   UPDATE complaint
   SET status = 'ACCEPTED', moderator_id = arg_moderator_id
   WHERE id = arg_complaint_id;

   PERFORM create_notification(c.target_user_id, 'RESTRICTION', 'Применены меры модерации',
       'Причина: ' || arg_reason
       || CASE WHEN arg_expires_at IS NOT NULL
               THEN '. Действует до ' || to_char(arg_expires_at, 'DD.MM.YYYY HH24:MI')
               ELSE '' END);
   RETURN new_restriction_id;
END;
$$ LANGUAGE plpgsql;


-- 8. Статистика платформы за период в формате JSON
CREATE OR REPLACE FUNCTION get_platform_stats(
   arg_from TIMESTAMPTZ DEFAULT now() - INTERVAL '30 days',
   arg_to TIMESTAMPTZ DEFAULT now())
RETURNS JSONB AS $$
DECLARE
   views_cnt BIGINT;
   likes_cnt BIGINT;
BEGIN
   SELECT COUNT(*) INTO views_cnt FROM profile_view
   WHERE created_at BETWEEN arg_from AND arg_to;
   SELECT COUNT(*) INTO likes_cnt FROM reaction
   WHERE type = 'LIKE' AND created_at BETWEEN arg_from AND arg_to;

   RETURN jsonb_build_object(
       'period', jsonb_build_object('from', arg_from, 'to', arg_to),
       'users_total', (SELECT COUNT(*) FROM users WHERE status <> 'DELETED'),
       'users_registered', (SELECT COUNT(*) FROM users
                            WHERE created_at BETWEEN arg_from AND arg_to),
       'users_active', (SELECT COUNT(DISTINCT uid) FROM (
                            SELECT from_user_id AS uid FROM reaction
                            WHERE created_at BETWEEN arg_from AND arg_to
                            UNION
                            SELECT sender_id FROM message
                            WHERE created_at BETWEEN arg_from AND arg_to) a),
       'views', views_cnt,
       'likes', likes_cnt,
       'dislikes', (SELECT COUNT(*) FROM reaction
                    WHERE type = 'DISLIKE' AND created_at BETWEEN arg_from AND arg_to),
       'likes_per_view', CASE WHEN views_cnt > 0
                              THEN round(likes_cnt::NUMERIC / views_cnt, 3) END,
       'matches', (SELECT COUNT(*) FROM match WHERE created_at BETWEEN arg_from AND arg_to),
       'matches_with_messages', (SELECT COUNT(*) FROM match m
                                 JOIN dialog d ON d.match_id = m.id
                                 WHERE m.created_at BETWEEN arg_from AND arg_to
                                   AND d.last_message_at IS NOT NULL),
       'messages', (SELECT COUNT(*) FROM message WHERE created_at BETWEEN arg_from AND arg_to),
       'complaints_by_status', COALESCE((SELECT jsonb_object_agg(status, cnt) FROM (
                                  SELECT status, COUNT(*) AS cnt FROM complaint
                                  WHERE created_at BETWEEN arg_from AND arg_to
                                  GROUP BY status) s), '{}'::JSONB),
       'complaints_by_reason', COALESCE((SELECT jsonb_object_agg(name, cnt) FROM (
                                  SELECT cr.name, COUNT(*) AS cnt FROM complaint c
                                  JOIN complaint_reason cr ON cr.id = c.reason_id
                                  WHERE c.created_at BETWEEN arg_from AND arg_to
                                  GROUP BY cr.name) s), '{}'::JSONB),
       'restrictions_by_type', COALESCE((SELECT jsonb_object_agg(type, cnt) FROM (
                                  SELECT type, COUNT(*) AS cnt FROM restriction
                                  WHERE created_at BETWEEN arg_from AND arg_to
                                  GROUP BY type) s), '{}'::JSONB)
   );
END;
$$ LANGUAGE plpgsql;


-- 9. Просмотр анкеты: фиксирует просмотр для статистики
CREATE OR REPLACE PROCEDURE record_profile_view(arg_viewer_id BIGINT, arg_profile_id BIGINT)
AS $$
BEGIN
   INSERT INTO profile_view (viewer_id, profile_id)
   SELECT arg_viewer_id, p.id FROM profile p
   WHERE p.id = arg_profile_id AND p.user_id <> arg_viewer_id;
END;
$$ LANGUAGE plpgsql;


-- 10. Прочтение диалога: отмечает сообщения собеседника прочитанными
CREATE OR REPLACE PROCEDURE mark_dialog_read(arg_user_id BIGINT, arg_dialog_id BIGINT)
AS $$
BEGIN
   IF NOT EXISTS (SELECT 1 FROM dialog d JOIN match m ON m.id = d.match_id
                  WHERE d.id = arg_dialog_id
                    AND arg_user_id IN (m.user1_id, m.user2_id)) THEN
       RAISE EXCEPTION 'Пользователь не является участником диалога';
   END IF;

   UPDATE message
   SET status = 'READ'
   WHERE dialog_id = arg_dialog_id
     AND sender_id <> arg_user_id
     AND status = 'SENT';
END;
$$ LANGUAGE plpgsql;
