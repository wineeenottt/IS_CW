-- 1. Пользователи, зарегистрированные за период (B-tree)
CREATE INDEX idx_users_created_at ON users (created_at);

-- 2. Поиск пользователя по началу email, LIKE 'abc%' (B-tree)
CREATE INDEX idx_users_email_prefix ON users (email varchar_pattern_ops);

-- 3. Фильтр по городу в ленте рекомендаций (hash)
CREATE INDEX idx_profile_city ON profile USING hash (city);

-- 4. Фильтр по полу и возрасту в ленте (B-tree)
CREATE INDEX idx_profile_gender_birth_date ON profile (gender, birth_date);

-- 5. Анкеты по интересу, подсчёт общих интересов (B-tree)
CREATE INDEX idx_profile_interest_interest ON profile_interest (interest_id, profile_id);

-- 6. Очередь фото на проверку модератором (B-tree, частичный)
CREATE INDEX idx_photo_pending ON photo (created_at) WHERE moderation_status = 'PENDING';

-- 7. Оценки конкретной анкеты и подсчёт лайков (B-tree)
CREATE INDEX idx_reaction_to_profile ON reaction (to_profile_id, type);

-- 8. Лайки, дизлайки и активные пользователи за период (B-tree, покрывающий)
CREATE INDEX idx_reaction_created_at ON reaction (created_at) INCLUDE (type, from_user_id);

-- 9. Совпадения пользователя, когда он второй в паре (hash)
CREATE INDEX idx_match_user2 ON match USING hash (user2_id);

-- 10. Совпадения за период (B-tree)
CREATE INDEX idx_match_created_at ON match (created_at);

-- 11. История диалога от новых сообщений к старым (B-tree)
CREATE INDEX idx_message_dialog_created ON message (dialog_id, created_at DESC, id DESC);

-- 12. Счётчик непрочитанных сообщений в диалогах (B-tree, частичный)
CREATE INDEX idx_message_unread ON message (dialog_id, sender_id) WHERE status = 'SENT';

-- 13. Сообщения и активность за период (B-tree)
CREATE INDEX idx_message_created_at ON message (created_at);

-- 14. Список уведомлений пользователя, новые сверху (B-tree)
CREATE INDEX idx_notification_user_created ON notification (user_id, created_at DESC);

-- 15. Счётчик непрочитанных уведомлений (B-tree, частичный)
CREATE INDEX idx_notification_unread ON notification (user_id) WHERE NOT is_read;

-- 16. Очередь отправки уведомлений в Telegram (B-tree, частичный)
CREATE INDEX idx_notification_telegram_queue ON notification (created_at)
    WHERE telegram_status IN ('PENDING', 'FAILED');

-- 17. Просмотры анкет за период (B-tree)
CREATE INDEX idx_profile_view_created_at ON profile_view (created_at);

-- 18. Просмотры конкретной анкеты (hash)
CREATE INDEX idx_profile_view_profile ON profile_view USING hash (profile_id);

-- 19. Очередь жалоб по статусу, старые первыми (B-tree)
CREATE INDEX idx_complaint_status_created ON complaint (status, created_at);

-- 20. Все жалобы на пользователя (hash)
CREATE INDEX idx_complaint_target ON complaint USING hash (target_user_id);

-- 21. Действующие ограничения пользователя (B-tree)
CREATE INDEX idx_restriction_user_type ON restriction (user_id, type, expires_at);

-- 22. Журнал за период, новые сверху (B-tree)
CREATE INDEX idx_journal_created_at ON journal (created_at DESC);

-- 23. Журнал по пользователю (B-tree)
CREATE INDEX idx_journal_user_created ON journal (user_id, created_at DESC);

-- 24. Журнал по типу действия (B-tree)
CREATE INDEX idx_journal_action_created ON journal (action, created_at DESC);

-- 25. История конкретного объекта в журнале (B-tree)
CREATE INDEX idx_journal_entity ON journal (entity_type, entity_id);
