-- ============================================
-- EDC Tickets — Migration 002: Lockout counter
-- Run this in Supabase SQL Editor
-- ============================================

-- Tracks failed PIN attempts per name
CREATE TABLE edc_attempts (
    name_lower TEXT PRIMARY KEY,
    attempts INT NOT NULL DEFAULT 0,
    locked_until TIMESTAMPTZ
);

ALTER TABLE edc_attempts ENABLE ROW LEVEL SECURITY;

-- No direct access — only through RPC functions

-- Replace lookup_order with lockout logic
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

    -- Check for existing lockout
    SELECT attempts, locked_until INTO v_attempts, v_locked_until
    FROM edc_attempts WHERE name_lower = v_name_lower;

    -- If locked and lock hasn't expired
    IF v_locked_until IS NOT NULL AND v_locked_until > now() THEN
        RETURN json_build_object(
            'error', 'Too many failed attempts. Try again in ' ||
                ceil(EXTRACT(EPOCH FROM (v_locked_until - now())) / 60)::int || ' minutes.',
            'locked', true,
            'locked_until', v_locked_until
        );
    END IF;

    -- If lock expired, reset
    IF v_locked_until IS NOT NULL AND v_locked_until <= now() THEN
        UPDATE edc_attempts SET attempts = 0, locked_until = NULL WHERE name_lower = v_name_lower;
        v_attempts := 0;
    END IF;

    -- Try lookup
    SELECT * INTO v_order FROM edc_orders
        WHERE lower(trim(buyer_name)) = v_name_lower
        AND pin_hash = p_pin_hash
        AND status != 'cancelled';

    IF v_order IS NULL THEN
        -- Increment failed attempts
        INSERT INTO edc_attempts (name_lower, attempts)
        VALUES (v_name_lower, 1)
        ON CONFLICT (name_lower)
        DO UPDATE SET attempts = edc_attempts.attempts + 1;

        -- Get updated count
        SELECT attempts INTO v_attempts FROM edc_attempts WHERE name_lower = v_name_lower;

        -- Lock if max reached
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

    -- Success — reset attempts
    DELETE FROM edc_attempts WHERE name_lower = v_name_lower;

    SELECT value::timestamptz INTO v_deadline FROM edc_config WHERE key = 'modification_deadline';
    v_can_modify := now() < v_deadline AND v_order.status IN ('pending', 'confirmed');

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
