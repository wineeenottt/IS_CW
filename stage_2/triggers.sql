-- 1. Возраст владельца анкеты не меньше 18 лет
CREATE OR REPLACE FUNCTION check_profile_age()
RETURNS TRIGGER AS $$
BEGIN
   IF NEW.birth_date > CURRENT_DATE - INTERVAL '18 years' THEN
       RAISE EXCEPTION 'Пользователю должно быть не меньше 18 лет';
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER profile_age_check
BEFORE INSERT OR UPDATE OF birth_date ON profile
FOR EACH ROW
EXECUTE FUNCTION check_profile_age();

-- 2. Автоматическое обновление updated_at при изменении анкеты и координат
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
   NEW.updated_at := now();
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER profile_set_updated_at
BEFORE UPDATE ON profile
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER location_set_updated_at
BEFORE UPDATE ON location
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- 3. Нельзя оценить собственную анкету
CREATE OR REPLACE FUNCTION check_reaction_not_self()
RETURNS TRIGGER AS $$
BEGIN
   IF EXISTS (SELECT 1 FROM profile
              WHERE id = NEW.to_profile_id AND user_id = NEW.from_user_id) THEN
       RAISE EXCEPTION 'Нельзя оценить собственную анкету';
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER reaction_not_self
BEFORE INSERT OR UPDATE ON reaction
FOR EACH ROW
EXECUTE FUNCTION check_reaction_not_self();

-- 4. Взаимный лайк создаёт совпадение и диалог
CREATE OR REPLACE FUNCTION create_match_on_mutual_like()
RETURNS TRIGGER AS $$
DECLARE
   target_user_id BIGINT;
   reverse_like_at TIMESTAMPTZ;
   new_match_id BIGINT;
BEGIN
   SELECT user_id INTO target_user_id FROM profile WHERE id = NEW.to_profile_id;

   SELECT r.created_at INTO reverse_like_at
   FROM reaction r
   JOIN profile p ON p.id = r.to_profile_id
   WHERE r.from_user_id = target_user_id
     AND p.user_id = NEW.from_user_id
     AND r.type = 'LIKE';
   IF reverse_like_at IS NULL THEN
       RETURN NEW;
   END IF;

   INSERT INTO match (user1_id, user2_id, created_at)
   VALUES (LEAST(NEW.from_user_id, target_user_id),
           GREATEST(NEW.from_user_id, target_user_id),
           CASE WHEN TG_OP = 'INSERT' THEN GREATEST(NEW.created_at, reverse_like_at)
                ELSE now() END)
   ON CONFLICT (user1_id, user2_id) DO NOTHING
   RETURNING id INTO new_match_id;

   IF new_match_id IS NOT NULL THEN
       INSERT INTO dialog (match_id, created_at)
       SELECT id, created_at FROM match WHERE id = new_match_id;
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER reaction_mutual_like
AFTER INSERT OR UPDATE OF type ON reaction
FOR EACH ROW
WHEN (NEW.type = 'LIKE')
EXECUTE FUNCTION create_match_on_mutual_like();

-- 5. Писать в диалог может только участник совпадения
CREATE OR REPLACE FUNCTION check_message_sender()
RETURNS TRIGGER AS $$
BEGIN
   IF NOT EXISTS (SELECT 1 FROM dialog d
                  JOIN match m ON m.id = d.match_id
                  WHERE d.id = NEW.dialog_id
                    AND NEW.sender_id IN (m.user1_id, m.user2_id)) THEN
       RAISE EXCEPTION 'Отправитель не является участником диалога';
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER message_sender_check
BEFORE INSERT OR UPDATE OF dialog_id, sender_id ON message
FOR EACH ROW
EXECUTE FUNCTION check_message_sender();

-- 6. Время последнего сообщения в диалоге
CREATE OR REPLACE FUNCTION update_dialog_last_message()
RETURNS TRIGGER AS $$
BEGIN
   UPDATE dialog
   SET last_message_at = GREATEST(COALESCE(last_message_at, NEW.created_at), NEW.created_at)
   WHERE id = NEW.dialog_id;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER message_update_dialog
AFTER INSERT ON message
FOR EACH ROW
EXECUTE FUNCTION update_dialog_last_message();

-- 7. Жалоба относится к анкете или сообщению нарушителя
CREATE OR REPLACE FUNCTION check_complaint_target()
RETURNS TRIGGER AS $$
BEGIN
   IF TG_OP = 'INSERT' AND NEW.profile_id IS NULL AND NEW.message_id IS NULL THEN
       RAISE EXCEPTION 'Жалоба должна относиться к анкете или сообщению';
   END IF;
   IF NEW.profile_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM profile
          WHERE id = NEW.profile_id AND user_id = NEW.target_user_id) THEN
       RAISE EXCEPTION 'Анкета не принадлежит пользователю, на которого подана жалоба';
   END IF;
   IF NEW.message_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM message
          WHERE id = NEW.message_id AND sender_id = NEW.target_user_id) THEN
       RAISE EXCEPTION 'Сообщение написано не тем пользователем, на которого подана жалоба';
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER complaint_target_check
BEFORE INSERT OR UPDATE OF target_user_id, profile_id, message_id ON complaint
FOR EACH ROW
EXECUTE FUNCTION check_complaint_target();

-- 8. Рассматривать жалобы и накладывать ограничения может только действующий модератор или администратор
CREATE OR REPLACE FUNCTION check_is_moderator(arg_user_id BIGINT)
RETURNS VOID AS $$
BEGIN
   IF arg_user_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM users
          WHERE id = arg_user_id
            AND role IN ('MODERATOR', 'ADMIN')
            AND status = 'ACTIVE') THEN
       RAISE EXCEPTION 'Пользователь % не является действующим модератором', arg_user_id;
   END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION check_complaint_moderator()
RETURNS TRIGGER AS $$
BEGIN
   PERFORM check_is_moderator(NEW.moderator_id);
   IF NEW.status <> 'NEW' AND NEW.moderator_id IS NULL THEN
       RAISE EXCEPTION 'Для смены статуса жалобы на % нужно указать модератора', NEW.status;
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER complaint_moderator_check
BEFORE INSERT OR UPDATE OF moderator_id, status ON complaint
FOR EACH ROW
EXECUTE FUNCTION check_complaint_moderator();

CREATE OR REPLACE FUNCTION check_restriction_moderator()
RETURNS TRIGGER AS $$
BEGIN
   PERFORM check_is_moderator(NEW.created_by);
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER restriction_moderator_check
BEFORE INSERT OR UPDATE OF created_by ON restriction
FOR EACH ROW
EXECUTE FUNCTION check_restriction_moderator();

-- 9. Пользователи удаляются только мягко, дата удаления проставляется автоматически
CREATE OR REPLACE FUNCTION fn_users_forbid_delete()
RETURNS TRIGGER AS $$
BEGIN
   RAISE EXCEPTION 'Физическое удаление пользователей запрещено: установите status = ''DELETED'''
       USING ERRCODE = 'restrict_violation';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_forbid_delete
BEFORE DELETE ON users
FOR EACH ROW
EXECUTE FUNCTION fn_users_forbid_delete();

CREATE OR REPLACE FUNCTION fn_users_set_deleted_at()
RETURNS TRIGGER AS $$
BEGIN
   IF NEW.status = 'DELETED' AND NEW.deleted_at IS NULL THEN
       NEW.deleted_at := now();
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_set_deleted_at
BEFORE INSERT OR UPDATE OF status ON users
FOR EACH ROW
EXECUTE FUNCTION fn_users_set_deleted_at();

-- 10. Вспомогательные функции: действующее ограничение пользователя и блокировка между пользователями
CREATE OR REPLACE FUNCTION has_active_restriction(arg_user_id BIGINT, arg_types VARCHAR[])
RETURNS BOOLEAN AS $$
BEGIN
   RETURN EXISTS (
       SELECT 1 FROM restriction
       WHERE user_id = arg_user_id
         AND type = ANY (arg_types)
         AND (expires_at IS NULL OR expires_at > now()));
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION is_blocked_between(arg_user1 BIGINT, arg_user2 BIGINT)
RETURNS BOOLEAN AS $$
BEGIN
   RETURN EXISTS (
       SELECT 1 FROM block
       WHERE (blocker_id = arg_user1 AND blocked_id = arg_user2)
          OR (blocker_id = arg_user2 AND blocked_id = arg_user1));
END;
$$ LANGUAGE plpgsql STABLE;

-- 11. Отправлять сообщения может только активный пользователь без бана и запрета сообщений, если собеседник его не заблокировал
CREATE OR REPLACE FUNCTION check_message_allowed()
RETURNS TRIGGER AS $$
DECLARE
   companion_id BIGINT;
BEGIN
   IF EXISTS (SELECT 1 FROM users WHERE id = NEW.sender_id AND status <> 'ACTIVE') THEN
       RAISE EXCEPTION 'Пользователь заблокирован или удалён';
   END IF;
   IF has_active_restriction(NEW.sender_id, ARRAY['BAN', 'NO_MESSAGES']) THEN
       RAISE EXCEPTION 'Пользователю запрещено отправлять сообщения';
   END IF;
   SELECT CASE WHEN m.user1_id = NEW.sender_id THEN m.user2_id ELSE m.user1_id END
   INTO companion_id
   FROM dialog d JOIN match m ON m.id = d.match_id
   WHERE d.id = NEW.dialog_id;

   IF is_blocked_between(NEW.sender_id, companion_id) THEN
       RAISE EXCEPTION 'Нельзя писать пользователю из-за блокировки';
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER message_allowed_check
BEFORE INSERT ON message
FOR EACH ROW
EXECUTE FUNCTION check_message_allowed();

-- 12. Оценивать анкеты может только активный пользователь без бана, при отсутствии блокировки между пользователями
CREATE OR REPLACE FUNCTION check_reaction_allowed()
RETURNS TRIGGER AS $$
DECLARE
   target_user_id BIGINT;
BEGIN
   IF EXISTS (SELECT 1 FROM users WHERE id = NEW.from_user_id AND status <> 'ACTIVE') THEN
       RAISE EXCEPTION 'Пользователь заблокирован или удалён';
   END IF;
   IF has_active_restriction(NEW.from_user_id, ARRAY['BAN']) THEN
       RAISE EXCEPTION 'Пользователь забанен';
   END IF;

   SELECT user_id INTO target_user_id FROM profile WHERE id = NEW.to_profile_id;
   IF is_blocked_between(NEW.from_user_id, target_user_id) THEN
       RAISE EXCEPTION 'Нельзя оценить анкету из-за блокировки';
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER reaction_allowed_check
BEFORE INSERT OR UPDATE ON reaction
FOR EACH ROW
EXECUTE FUNCTION check_reaction_allowed();

-- 13. Ограничение можно наложить только на обычного пользователя
CREATE OR REPLACE FUNCTION check_restriction_target()
RETURNS TRIGGER AS $$
BEGIN
   IF EXISTS (SELECT 1 FROM users WHERE id = NEW.user_id AND role <> 'USER') THEN
       RAISE EXCEPTION 'Нельзя наложить ограничение на модератора или администратора';
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER restriction_target_check
BEFORE INSERT OR UPDATE OF user_id ON restriction
FOR EACH ROW
EXECUTE FUNCTION check_restriction_target();

-- 14. Журнал важных действий: смена статуса пользователя, наложение ограничения, смена статуса жалобы
CREATE OR REPLACE FUNCTION log_user_status_change()
RETURNS TRIGGER AS $$
BEGIN
   IF NEW.status IS DISTINCT FROM OLD.status THEN
       INSERT INTO journal (user_id, action, entity_type, entity_id, details)
       VALUES (NULL, 'USER_STATUS_CHANGED', 'users', NEW.id,
               jsonb_build_object('old_status', OLD.status, 'new_status', NEW.status));
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_log_status
AFTER UPDATE OF status ON users
FOR EACH ROW
EXECUTE FUNCTION log_user_status_change();

CREATE OR REPLACE FUNCTION log_restriction_created()
RETURNS TRIGGER AS $$
BEGIN
   INSERT INTO journal (user_id, action, entity_type, entity_id, details)
   VALUES (NEW.created_by, 'RESTRICTION_CREATED', 'restriction', NEW.id,
           jsonb_build_object('user_id', NEW.user_id, 'type', NEW.type,
                              'expires_at', NEW.expires_at, 'complaint_id', NEW.complaint_id));
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER restriction_log_created
AFTER INSERT ON restriction
FOR EACH ROW
EXECUTE FUNCTION log_restriction_created();

CREATE OR REPLACE FUNCTION log_complaint_status_change()
RETURNS TRIGGER AS $$
BEGIN
   IF NEW.status IS DISTINCT FROM OLD.status THEN
       INSERT INTO journal (user_id, action, entity_type, entity_id, details)
       VALUES (NEW.moderator_id, 'COMPLAINT_STATUS_CHANGED', 'complaint', NEW.id,
               jsonb_build_object('old_status', OLD.status, 'new_status', NEW.status));
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER complaint_log_status
AFTER UPDATE OF status ON complaint
FOR EACH ROW
EXECUTE FUNCTION log_complaint_status_change();

-- 15. Первое фото анкеты автоматически становится главным
CREATE OR REPLACE FUNCTION set_first_photo_main()
RETURNS TRIGGER AS $$
BEGIN
   IF NOT EXISTS (SELECT 1 FROM photo WHERE profile_id = NEW.profile_id) THEN
       NEW.is_main := TRUE;
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER photo_first_main
BEFORE INSERT ON photo
FOR EACH ROW
EXECUTE FUNCTION set_first_photo_main();

-- 16. Не больше 5 фото на анкету
CREATE OR REPLACE FUNCTION check_photo_limit()
RETURNS TRIGGER AS $$
BEGIN
   IF TG_OP = 'UPDATE' AND NEW.profile_id = OLD.profile_id THEN
       RETURN NEW;
   END IF;

   PERFORM 1 FROM profile WHERE id = NEW.profile_id FOR UPDATE;

   IF (SELECT COUNT(*) FROM photo WHERE profile_id = NEW.profile_id) >= 5 THEN
       RAISE EXCEPTION 'В анкете может быть не больше 5 фото';
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER photo_limit
BEFORE INSERT OR UPDATE OF profile_id ON photo
FOR EACH ROW
EXECUTE FUNCTION check_photo_limit();

-- 17. При выборе нового главного фото у остальных фото анкеты флаг снимается
CREATE OR REPLACE FUNCTION reset_other_main_photos()
RETURNS TRIGGER AS $$
BEGIN
   UPDATE photo
   SET is_main = FALSE
   WHERE profile_id = NEW.profile_id
     AND is_main
     AND id <> NEW.id;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER photo_single_main
BEFORE INSERT OR UPDATE OF is_main ON photo
FOR EACH ROW
WHEN (NEW.is_main)
EXECUTE FUNCTION reset_other_main_photos();

-- 18. Автоматическое заполнение даты рассмотрения жалобы
CREATE OR REPLACE FUNCTION set_complaint_resolved_at()
RETURNS TRIGGER AS $$
BEGIN
   IF NEW.status IN ('REJECTED', 'ACCEPTED') THEN
       IF TG_OP = 'INSERT' OR OLD.status NOT IN ('REJECTED', 'ACCEPTED') THEN
           NEW.resolved_at := COALESCE(NEW.resolved_at, now());
       END IF;
   ELSE
       NEW.resolved_at := NULL;
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER complaint_set_resolved_at
BEFORE INSERT OR UPDATE OF status ON complaint
FOR EACH ROW
EXECUTE FUNCTION set_complaint_resolved_at();

-- 19. Токен одноразовый и не может быть использован после истечения срока
CREATE OR REPLACE FUNCTION check_token_usage()
RETURNS TRIGGER AS $$
BEGIN
   IF OLD.used_at IS NOT NULL AND NEW.used_at IS DISTINCT FROM OLD.used_at THEN
       RAISE EXCEPTION 'Токен уже использован';
   END IF;
   IF OLD.used_at IS NULL AND NEW.used_at IS NOT NULL AND OLD.expires_at <= now() THEN
       RAISE EXCEPTION 'Срок действия токена истёк';
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER auth_token_usage_check
BEFORE UPDATE OF used_at ON auth_token
FOR EACH ROW
EXECUTE FUNCTION check_token_usage();

-- 20. Токен нельзя создать с уже истёкшим сроком
CREATE OR REPLACE FUNCTION check_token_expires()
RETURNS TRIGGER AS $$
BEGIN
   IF NEW.expires_at <= now() THEN
       RAISE EXCEPTION 'Срок действия токена должен быть в будущем';
   END IF;
   RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER auth_token_expires_check
BEFORE INSERT ON auth_token
FOR EACH ROW
EXECUTE FUNCTION check_token_expires();
