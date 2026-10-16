BEGIN;

INSERT INTO users (email, password_hash, email_verified, telegram_id, role, created_at)
SELECT v.email,
       '$2a$10$7EqJtq98hPqEX7fNZaFWoOa8nq2PyZ1Q6u3m2uGqBq6c0yQhV9cKi',
       v.verified, v.tg, v.role, now() - make_interval(days => v.days_ago)
FROM (VALUES
    ('admin@dating.test',  true,  NULL::bigint, 'ADMIN',     60),
    ('moder@dating.test',  true,  NULL,         'MODERATOR', 58),
    ('anna@dating.test',   true,  100000001,    'USER',      40),
    ('boris@dating.test',  true,  100000002,    'USER',      39),
    ('vera@dating.test',   true,  NULL,         'USER',      35),
    ('gleb@dating.test',   true,  NULL,         'USER',      34),
    ('daria@dating.test',  true,  NULL,         'USER',      30),
    ('egor@dating.test',   true,  NULL,         'USER',      29),
    ('newbie@dating.test', false, NULL,         'USER',       1)
) AS v(email, verified, tg, role, days_ago);

INSERT INTO profile (user_id, name, birth_date, gender, looking_for, city, description, created_at, updated_at)
SELECT u.id, v.name, v.birth, v.gender, v.looking_for, v.city, v.descr,
       u.created_at + interval '1 hour', u.created_at + interval '1 hour'
FROM (VALUES
    ('anna@dating.test',  'Анна',  DATE '1999-03-14', 'FEMALE', 'MALE',   'Санкт-Петербург', 'Люблю кино и долгие прогулки.'),
    ('boris@dating.test', 'Борис', DATE '1996-07-02', 'MALE',   'FEMALE', 'Санкт-Петербург', 'Программист, по выходным хожу в походы.'),
    ('vera@dating.test',  'Вера',  DATE '2000-11-23', 'FEMALE', 'MALE',   'Москва',          'Читаю, слушаю музыку.'),
    ('gleb@dating.test',  'Глеб',  DATE '1995-01-30', 'MALE',   'FEMALE', 'Москва',          NULL),
    ('daria@dating.test', 'Дарья', DATE '1998-05-19', 'FEMALE', 'MALE',   'Казань',          'Люблю путешествия и спорт.'),
    ('egor@dating.test',  'Егор',  DATE '1997-09-08', 'MALE',   'FEMALE', 'Казань',          'Спорт и хорошее кино.')
) AS v(email, name, birth, gender, looking_for, city, descr)
JOIN users u ON u.email = v.email
ORDER BY u.id;

INSERT INTO location (profile_id, latitude, longitude)
SELECT p.id, v.lat, v.lon
FROM (VALUES
    ('anna@dating.test',  59.939095, 30.315868),
    ('boris@dating.test', 59.956300, 30.308800),
    ('vera@dating.test',  55.755826, 37.617300),
    ('gleb@dating.test',  55.790000, 37.560000),
    ('daria@dating.test', 55.796127, 49.106414)
) AS v(email, lat, lon)
JOIN users u ON u.email = v.email
JOIN profile p ON p.user_id = u.id;

INSERT INTO interest (name) VALUES
    ('Музыка'), ('Кино'), ('Путешествия'), ('Спорт'), ('Чтение'), ('Программирование');

INSERT INTO profile_interest (profile_id, interest_id)
SELECT p.id, i.id
FROM (VALUES
    ('anna@dating.test',  'Кино'),   ('anna@dating.test',  'Путешествия'), ('anna@dating.test',  'Чтение'),
    ('boris@dating.test', 'Программирование'), ('boris@dating.test', 'Кино'), ('boris@dating.test', 'Путешествия'),
    ('vera@dating.test',  'Чтение'), ('vera@dating.test',  'Музыка'),
    ('gleb@dating.test',  'Музыка'), ('gleb@dating.test',  'Спорт'),
    ('daria@dating.test', 'Путешествия'), ('daria@dating.test', 'Спорт'),
    ('egor@dating.test',  'Спорт'),  ('egor@dating.test',  'Кино')
) AS v(email, interest)
JOIN users u ON u.email = v.email
JOIN profile p ON p.user_id = u.id
JOIN interest i ON i.name = v.interest;

INSERT INTO photo (profile_id, url, is_main, sort_order, moderation_status, created_at)
SELECT p.id,
       'https://photos.dating.test/' || split_part(v.email, '@', 1) || '/' || v.n || '.jpg',
       v.n = 0, v.n, v.status, p.created_at + interval '2 hours'
FROM (VALUES
    ('anna@dating.test',  0, 'APPROVED'), ('anna@dating.test', 1, 'APPROVED'),
    ('boris@dating.test', 0, 'APPROVED'),
    ('vera@dating.test',  0, 'APPROVED'), ('vera@dating.test', 1, 'PENDING'),
    ('gleb@dating.test',  0, 'APPROVED'),
    ('daria@dating.test', 0, 'APPROVED'),
    ('egor@dating.test',  0, 'HIDDEN')       -- скрыто модератором
) AS v(email, n, status)
JOIN users u ON u.email = v.email
JOIN profile p ON p.user_id = u.id;

INSERT INTO reaction (from_user_id, to_profile_id, type, created_at)
SELECT f.id, p.id, v.type, now() - make_interval(hours => v.hours_ago)
FROM (VALUES
    ('anna@dating.test',  'boris@dating.test', 'LIKE',    300),
    ('boris@dating.test', 'anna@dating.test',  'LIKE',    290),
    ('anna@dating.test',  'gleb@dating.test',  'LIKE',    280),
    ('gleb@dating.test',  'anna@dating.test',  'DISLIKE', 270),
    ('anna@dating.test',  'egor@dating.test',  'DISLIKE', 260),
    ('vera@dating.test',  'gleb@dating.test',  'LIKE',    250),
    ('gleb@dating.test',  'vera@dating.test',  'LIKE',    240),
    ('boris@dating.test', 'vera@dating.test',  'LIKE',    230),
    ('vera@dating.test',  'boris@dating.test', 'DISLIKE', 220),
    ('daria@dating.test', 'egor@dating.test',  'LIKE',    200),
    ('egor@dating.test',  'daria@dating.test', 'LIKE',    190),
    ('boris@dating.test', 'daria@dating.test', 'LIKE',    180)
) AS v(from_email, to_email, type, hours_ago)
JOIN users f   ON f.email = v.from_email
JOIN users t   ON t.email = v.to_email
JOIN profile p ON p.user_id = t.id
ORDER BY v.hours_ago DESC;

INSERT INTO message (dialog_id, sender_id, text, status, created_at)
SELECT d.id, s.id, v.text, v.status, m.created_at + make_interval(mins => v.mins)
FROM (VALUES
    ('anna@dating.test',  'boris@dating.test', 'anna@dating.test',  'Привет! Увидела, что ты ходишь в походы',    'READ',   5),
    ('anna@dating.test',  'boris@dating.test', 'boris@dating.test', 'Привет, Анна! Да, в июле был на Алтае',        'READ',  12),
    ('anna@dating.test',  'boris@dating.test', 'anna@dating.test',  'Давай как-нибудь сходим в кино?',              'SENT',  40),
    ('vera@dating.test',  'gleb@dating.test',  'gleb@dating.test',  'Вера, привет! Какую музыку слушаешь?',         'READ',   3),
    ('vera@dating.test',  'gleb@dating.test',  'vera@dating.test',  'Привет! Больше всего джаз',                    'SENT',  15),
    ('daria@dating.test', 'egor@dating.test',  'egor@dating.test',  'Привет! Тоже люблю спорт',                     'READ',   2),
    ('daria@dating.test', 'egor@dating.test',  'daria@dating.test', 'Привет, Егор! Чем занимаешься?',               'READ',  10),
    ('daria@dating.test', 'egor@dating.test',  'egor@dating.test',  'Ты скучная, лучше бы вообще мне не писала',    'HIDDEN', 25)
) AS v(a, b, sender, text, status, mins)
JOIN users ua ON ua.email = v.a
JOIN users ub ON ub.email = v.b
JOIN match m  ON m.user1_id = least(ua.id, ub.id) AND m.user2_id = greatest(ua.id, ub.id)
JOIN dialog d ON d.match_id = m.id
JOIN users s  ON s.email = v.sender
ORDER BY m.id, v.mins;

-- блокировка: Дарья заблокировала Егора после оскорбления
INSERT INTO block (blocker_id, blocked_id, created_at)
SELECT b.id, t.id, now() - interval '6 days'
FROM users b, users t
WHERE b.email = 'daria@dating.test' AND t.email = 'egor@dating.test';

INSERT INTO complaint_reason (name, description) VALUES
    ('Спам',              'Рекламные и массовые сообщения'),
    ('Оскорбления',       'Грубые и оскорбительные сообщения'),
    ('Фейковая анкета',   'Анкета содержит заведомо ложные сведения'),
    ('Неприемлемые фото', 'Фотографии нарушают правила платформы');

INSERT INTO complaint (reporter_id, target_user_id, moderator_id, profile_id, message_id,
                       reason_id, comment, status, created_at, resolved_at)
SELECT r.id, t.id, m.id, p.id, msg.id, cr.id, v.comment, v.status,
       now() - make_interval(days => v.days_ago),
       CASE WHEN v.status IN ('REJECTED', 'ACCEPTED') THEN now() - make_interval(days => v.days_ago - 1) END
FROM (VALUES
    ('daria@dating.test', 'egor@dating.test',  'moder@dating.test', false, 'Ты скучная, лучше бы вообще мне не писала',
        'Оскорбления',       'Оскорбил в личных сообщениях', 'ACCEPTED',  7),
    ('vera@dating.test',  'gleb@dating.test',  'moder@dating.test', true,  NULL,
        'Фейковая анкета',   'Фото похожи на снимки из интернета', 'IN_REVIEW', 4),
    ('anna@dating.test',  'egor@dating.test',  NULL,                true,  NULL,
        'Спам',              'Пишет всем одно и то же',       'NEW',       2),
    ('gleb@dating.test',  'boris@dating.test', 'moder@dating.test', true,  NULL,
        'Неприемлемые фото', NULL,                            'REJECTED',  9),
    ('boris@dating.test', 'egor@dating.test',  'moder@dating.test', true,  NULL,
        'Спам',              'Просил перейти по ссылке',      'NEED_INFO', 6)
) AS v(reporter, target, moderator, on_profile, msg_text, reason, comment, status, days_ago)
JOIN users r ON r.email = v.reporter
JOIN users t ON t.email = v.target
LEFT JOIN users m ON m.email = v.moderator
LEFT JOIN profile p ON v.on_profile AND p.user_id = t.id
LEFT JOIN message msg ON msg.text = v.msg_text
JOIN complaint_reason cr ON cr.name = v.reason
ORDER BY v.days_ago DESC;

INSERT INTO restriction (user_id, type, reason, complaint_id, created_by, created_at, expires_at)
SELECT u.id, v.type, v.reason, c.id, a.id,
       now() - make_interval(days => v.days_ago),
       now() - make_interval(days => v.days_ago) + make_interval(days => v.days_valid)
FROM (VALUES
    ('egor@dating.test', 'NO_MESSAGES',  'Оскорбления в личных сообщениях', true,  'moder@dating.test', 6, 14),
    ('gleb@dating.test', 'HIDE_PROFILE', 'Анкета скрыта до проверки фото', false, 'admin@dating.test', 3,  7)
) AS v(email, type, reason, by_complaint, creator, days_ago, days_valid)
JOIN users u ON u.email = v.email
JOIN users a ON a.email = v.creator
LEFT JOIN complaint c ON v.by_complaint AND c.target_user_id = u.id AND c.status = 'ACCEPTED';

COMMIT;
