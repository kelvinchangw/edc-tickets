-- ============================================
-- EDC Tickets — Migration 004: Security fixes
-- Run this in Supabase SQL Editor
-- ============================================

-- 1. FIX CRITICAL: Admin password publicly readable
--    Restrict config SELECT to exclude admin_password
DROP POLICY "Anyone can read config" ON edc_config;
CREATE POLICY "Anyone can read config (except admin password)"
    ON edc_config FOR SELECT
    USING (key != 'admin_password');

-- 2. FIX CRITICAL: Hash the admin password
--    Update admin_password to a SHA-256 hash
--    IMPORTANT: After running this, go to edc_config and update admin_password
--    to the SHA-256 hash of your password. You can get it from the browser console:
--
--    async function hash(s) {
--      const h = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
--      return Array.from(new Uint8Array(h)).map(b=>b.toString(16).padStart(2,'0')).join('');
--    }
--    hash('your_password_here').then(console.log)
--
--    Then run: UPDATE edc_config SET value = '<the_hash>' WHERE key = 'admin_password';

-- 3. FIX MEDIUM: Update admin RPC functions to compare hashed passwords
CREATE OR REPLACE FUNCTION admin_get_orders(p_password TEXT)
RETURNS JSON AS $$
DECLARE
    v_admin_pw TEXT;
    v_orders JSON;
BEGIN
    SELECT value INTO v_admin_pw FROM edc_config WHERE key = 'admin_password';
    IF p_password != v_admin_pw THEN
        RETURN json_build_object('error', 'Invalid admin password');
    END IF;

    SELECT json_agg(
        json_build_object(
            'id', id,
            'buyer_name', buyer_name,
            'email', email,
            'ticket_type', ticket_type,
            'status', status,
            'zelle_screenshot_url', zelle_screenshot_url,
            'created_at', created_at,
            'updated_at', updated_at
        ) ORDER BY created_at DESC
    ) INTO v_orders FROM edc_orders;

    RETURN json_build_object('success', true, 'orders', COALESCE(v_orders, '[]'::json));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_update_status(
    p_password TEXT,
    p_order_id UUID,
    p_status TEXT
) RETURNS JSON AS $$
DECLARE
    v_admin_pw TEXT;
BEGIN
    SELECT value INTO v_admin_pw FROM edc_config WHERE key = 'admin_password';
    IF p_password != v_admin_pw THEN
        RETURN json_build_object('error', 'Invalid admin password');
    END IF;

    IF p_status NOT IN ('pending', 'confirmed', 'paid', 'fulfilled', 'cancelled') THEN
        RETURN json_build_object('error', 'Invalid status');
    END IF;

    UPDATE edc_orders
    SET status = p_status, updated_at = now()
    WHERE id = p_order_id;

    IF NOT FOUND THEN
        RETURN json_build_object('error', 'Order not found');
    END IF;

    RETURN json_build_object('success', true, 'message', 'Status updated');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION admin_update_config(
    p_password TEXT,
    p_key TEXT,
    p_value TEXT
) RETURNS JSON AS $$
DECLARE
    v_admin_pw TEXT;
BEGIN
    SELECT value INTO v_admin_pw FROM edc_config WHERE key = 'admin_password';
    IF p_password != v_admin_pw THEN
        RETURN json_build_object('error', 'Invalid admin password');
    END IF;

    -- Only allow updating safe config keys
    IF p_key NOT IN ('orders_open', 'ga_price', 'ga_plus_price', 'vip_price', 'modification_deadline', 'event_name') THEN
        RETURN json_build_object('error', 'Cannot update this config key');
    END IF;

    UPDATE edc_config SET value = p_value WHERE key = p_key;

    IF NOT FOUND THEN
        RETURN json_build_object('error', 'Config key not found');
    END IF;

    RETURN json_build_object('success', true, 'message', 'Config updated');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. FIX MEDIUM: Add lockout to update_order, cancel_order, save_zelle_screenshot
CREATE OR REPLACE FUNCTION update_order(
    p_name TEXT,
    p_pin_hash TEXT,
    p_ticket_type TEXT
) RETURNS JSON AS $$
DECLARE
    v_order edc_orders;
    v_deadline TIMESTAMPTZ;
    v_name_lower TEXT;
    v_attempts INT;
    v_locked_until TIMESTAMPTZ;
BEGIN
    v_name_lower := lower(trim(p_name));

    -- Check lockout
    SELECT attempts, locked_until INTO v_attempts, v_locked_until
    FROM edc_attempts WHERE name_lower = v_name_lower;

    IF v_locked_until IS NOT NULL AND v_locked_until > now() THEN
        RETURN json_build_object('error', 'Too many failed attempts. Try again later.', 'locked', true);
    END IF;

    IF p_ticket_type NOT IN ('ga', 'ga_plus', 'vip') THEN
        RETURN json_build_object('error', 'Invalid ticket type');
    END IF;

    SELECT value::timestamptz INTO v_deadline FROM edc_config WHERE key = 'modification_deadline';
    IF now() > v_deadline THEN
        RETURN json_build_object('error', 'The modification deadline has passed');
    END IF;

    SELECT * INTO v_order FROM edc_orders
        WHERE lower(trim(buyer_name)) = v_name_lower
        AND pin_hash = p_pin_hash
        AND status IN ('pending', 'confirmed');

    IF v_order IS NULL THEN
        -- Increment failed attempts
        INSERT INTO edc_attempts (name_lower, attempts)
        VALUES (v_name_lower, 1)
        ON CONFLICT (name_lower)
        DO UPDATE SET attempts = edc_attempts.attempts + 1;

        SELECT attempts INTO v_attempts FROM edc_attempts WHERE name_lower = v_name_lower;
        IF v_attempts >= 5 THEN
            UPDATE edc_attempts SET locked_until = now() + interval '15 minutes' WHERE name_lower = v_name_lower;
        END IF;

        RETURN json_build_object('error', 'No modifiable order found');
    END IF;

    DELETE FROM edc_attempts WHERE name_lower = v_name_lower;

    UPDATE edc_orders
    SET ticket_type = p_ticket_type, updated_at = now()
    WHERE id = v_order.id;

    RETURN json_build_object('success', true, 'message', 'Order updated');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION cancel_order(
    p_name TEXT,
    p_pin_hash TEXT
) RETURNS JSON AS $$
DECLARE
    v_order edc_orders;
    v_deadline TIMESTAMPTZ;
    v_name_lower TEXT;
    v_attempts INT;
    v_locked_until TIMESTAMPTZ;
BEGIN
    v_name_lower := lower(trim(p_name));

    SELECT attempts, locked_until INTO v_attempts, v_locked_until
    FROM edc_attempts WHERE name_lower = v_name_lower;

    IF v_locked_until IS NOT NULL AND v_locked_until > now() THEN
        RETURN json_build_object('error', 'Too many failed attempts. Try again later.', 'locked', true);
    END IF;

    SELECT value::timestamptz INTO v_deadline FROM edc_config WHERE key = 'modification_deadline';
    IF now() > v_deadline THEN
        RETURN json_build_object('error', 'The modification deadline has passed');
    END IF;

    SELECT * INTO v_order FROM edc_orders
        WHERE lower(trim(buyer_name)) = v_name_lower
        AND pin_hash = p_pin_hash
        AND status IN ('pending', 'confirmed');

    IF v_order IS NULL THEN
        INSERT INTO edc_attempts (name_lower, attempts)
        VALUES (v_name_lower, 1)
        ON CONFLICT (name_lower)
        DO UPDATE SET attempts = edc_attempts.attempts + 1;

        SELECT attempts INTO v_attempts FROM edc_attempts WHERE name_lower = v_name_lower;
        IF v_attempts >= 5 THEN
            UPDATE edc_attempts SET locked_until = now() + interval '15 minutes' WHERE name_lower = v_name_lower;
        END IF;

        RETURN json_build_object('error', 'No cancellable order found');
    END IF;

    DELETE FROM edc_attempts WHERE name_lower = v_name_lower;

    UPDATE edc_orders
    SET status = 'cancelled', updated_at = now()
    WHERE id = v_order.id;

    RETURN json_build_object('success', true, 'message', 'Order cancelled');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION save_zelle_screenshot(
    p_name TEXT,
    p_pin_hash TEXT,
    p_screenshot_url TEXT
) RETURNS JSON AS $$
DECLARE
    v_order edc_orders;
    v_name_lower TEXT;
    v_attempts INT;
    v_locked_until TIMESTAMPTZ;
BEGIN
    v_name_lower := lower(trim(p_name));

    SELECT attempts, locked_until INTO v_attempts, v_locked_until
    FROM edc_attempts WHERE name_lower = v_name_lower;

    IF v_locked_until IS NOT NULL AND v_locked_until > now() THEN
        RETURN json_build_object('error', 'Too many failed attempts. Try again later.', 'locked', true);
    END IF;

    SELECT * INTO v_order FROM edc_orders
        WHERE lower(trim(buyer_name)) = v_name_lower
        AND pin_hash = p_pin_hash
        AND status != 'cancelled';

    IF v_order IS NULL THEN
        INSERT INTO edc_attempts (name_lower, attempts)
        VALUES (v_name_lower, 1)
        ON CONFLICT (name_lower)
        DO UPDATE SET attempts = edc_attempts.attempts + 1;

        SELECT attempts INTO v_attempts FROM edc_attempts WHERE name_lower = v_name_lower;
        IF v_attempts >= 5 THEN
            UPDATE edc_attempts SET locked_until = now() + interval '15 minutes' WHERE name_lower = v_name_lower;
        END IF;

        RETURN json_build_object('error', 'No order found');
    END IF;

    DELETE FROM edc_attempts WHERE name_lower = v_name_lower;

    UPDATE edc_orders
    SET zelle_screenshot_url = p_screenshot_url, updated_at = now()
    WHERE id = v_order.id;

    RETURN json_build_object('success', true, 'message', 'Screenshot saved');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. FIX MEDIUM: Restrict storage uploads to image types only
--    Drop old permissive policy and create restricted one
DROP POLICY "Anyone can upload screenshots" ON storage.objects;
CREATE POLICY "Anyone can upload image screenshots"
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'edc-zelle-screenshots'
        AND (storage.extension(name) IN ('jpg', 'jpeg', 'png', 'webp', 'heic'))
    );

-- Also add UPDATE policy so upsert works for replacing screenshots
CREATE POLICY "Anyone can update screenshots"
    ON storage.objects FOR UPDATE
    USING (bucket_id = 'edc-zelle-screenshots')
    WITH CHECK (bucket_id = 'edc-zelle-screenshots');
