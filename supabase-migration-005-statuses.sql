-- ============================================
-- EDC Tickets — Migration 005: Updated statuses
-- Run this in Supabase SQL Editor
-- ============================================

-- 1. Drop the old CHECK constraint and add new one with updated statuses
ALTER TABLE edc_orders DROP CONSTRAINT IF EXISTS edc_orders_status_check;
ALTER TABLE edc_orders ADD CONSTRAINT edc_orders_status_check
    CHECK (status IN ('pending', 'awaiting_payment', 'paid', 'verified', 'fulfilled', 'cancelled'));

-- 2. Update save_zelle_screenshot to auto-set status to 'paid'
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
    SET zelle_screenshot_url = p_screenshot_url,
        status = 'paid',
        updated_at = now()
    WHERE id = v_order.id;

    RETURN json_build_object('success', true, 'message', 'Screenshot uploaded. Status updated to Paid.');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. Update admin_update_status with new valid statuses
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

    IF p_status NOT IN ('pending', 'awaiting_payment', 'paid', 'verified', 'fulfilled', 'cancelled') THEN
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

-- 4. Update lookup_order can_modify to include awaiting_payment
CREATE OR REPLACE FUNCTION lookup_order(
    p_name TEXT,
    p_pin_hash TEXT
) RETURNS JSON AS $$
DECLARE
    v_order edc_orders;
    v_deadline TIMESTAMPTZ;
    v_can_modify BOOLEAN;
    v_name_lower TEXT;
    v_attempts INT;
    v_locked_until TIMESTAMPTZ;
    v_max_attempts INT := 5;
    v_lockout_minutes INT := 15;
BEGIN
    v_name_lower := lower(trim(p_name));

    SELECT attempts, locked_until INTO v_attempts, v_locked_until
    FROM edc_attempts WHERE name_lower = v_name_lower;

    IF v_locked_until IS NOT NULL AND v_locked_until > now() THEN
        RETURN json_build_object(
            'error', 'Too many failed attempts. Try again in ' ||
                ceil(EXTRACT(EPOCH FROM (v_locked_until - now())) / 60)::int || ' minutes.',
            'locked', true,
            'locked_until', v_locked_until
        );
    END IF;

    IF v_locked_until IS NOT NULL AND v_locked_until <= now() THEN
        UPDATE edc_attempts SET attempts = 0, locked_until = NULL WHERE name_lower = v_name_lower;
        v_attempts := 0;
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

        IF v_attempts >= v_max_attempts THEN
            UPDATE edc_attempts
            SET locked_until = now() + (v_lockout_minutes || ' minutes')::interval
            WHERE name_lower = v_name_lower;

            RETURN json_build_object(
                'error', 'Too many failed attempts. Locked for ' || v_lockout_minutes || ' minutes.',
                'locked', true,
                'attempts_remaining', 0
            );
        END IF;

        RETURN json_build_object(
            'error', 'No order found. Check your name and PIN.',
            'attempts_remaining', v_max_attempts - v_attempts
        );
    END IF;

    DELETE FROM edc_attempts WHERE name_lower = v_name_lower;

    SELECT value::timestamptz INTO v_deadline FROM edc_config WHERE key = 'modification_deadline';
    v_can_modify := now() < v_deadline AND v_order.status IN ('pending', 'awaiting_payment');

    RETURN json_build_object(
        'success', true,
        'order', json_build_object(
            'id', v_order.id,
            'buyer_name', v_order.buyer_name,
            'email', v_order.email,
            'ticket_type', v_order.ticket_type,
            'status', v_order.status,
            'zelle_screenshot_url', v_order.zelle_screenshot_url,
            'created_at', v_order.created_at,
            'updated_at', v_order.updated_at
        ),
        'can_modify', v_can_modify,
        'deadline', v_deadline
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Update submit_order to reference new statuses
CREATE OR REPLACE FUNCTION submit_order(
    p_name TEXT,
    p_email TEXT,
    p_pin_hash TEXT,
    p_ticket_type TEXT
) RETURNS JSON AS $$
DECLARE
    v_existing UUID;
    v_deadline TIMESTAMPTZ;
    v_orders_open BOOLEAN;
    v_order edc_orders;
BEGIN
    SELECT (value = 'true') INTO v_orders_open FROM edc_config WHERE key = 'orders_open';
    IF NOT v_orders_open THEN
        RETURN json_build_object('error', 'Orders are currently closed');
    END IF;

    SELECT value::timestamptz INTO v_deadline FROM edc_config WHERE key = 'modification_deadline';
    IF now() > v_deadline THEN
        RETURN json_build_object('error', 'The order deadline has passed');
    END IF;

    SELECT id INTO v_existing FROM edc_orders
        WHERE lower(trim(buyer_name)) = lower(trim(p_name))
        AND status != 'cancelled';
    IF v_existing IS NOT NULL THEN
        RETURN json_build_object('error', 'An order already exists for this name. Use Check Order to modify it.');
    END IF;

    INSERT INTO edc_orders (buyer_name, email, pin_hash, ticket_type)
    VALUES (trim(p_name), trim(p_email), p_pin_hash, p_ticket_type)
    RETURNING * INTO v_order;

    RETURN json_build_object(
        'success', true,
        'order', json_build_object(
            'id', v_order.id,
            'buyer_name', v_order.buyer_name,
            'ticket_type', v_order.ticket_type,
            'status', v_order.status,
            'created_at', v_order.created_at
        )
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. Update update_order with new modifiable statuses
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
        AND status IN ('pending', 'awaiting_payment');

    IF v_order IS NULL THEN
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

-- 7. Update cancel_order with new modifiable statuses
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
        AND status IN ('pending', 'awaiting_payment');

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
