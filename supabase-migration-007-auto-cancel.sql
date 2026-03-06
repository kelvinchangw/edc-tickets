-- ============================================
-- EDC Tickets — Migration 007: Auto-cancel expired unpaid orders
-- Run this in Supabase SQL Editor
-- ============================================
-- Orders in 'pending' or 'awaiting_payment' status are auto-cancelled
-- 21 days after the modification_deadline (order submission window close).
-- Cancellation emails are sent via the existing send_status_change_email function.
-- A pg_cron job runs every hour to auto-cancel without any user action needed.

-- 1. Enable pg_cron extension
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

-- 2. Grant usage so cron jobs can call our functions
GRANT USAGE ON SCHEMA public TO postgres;

-- 3. Bulk auto-cancel function
CREATE OR REPLACE FUNCTION auto_cancel_expired_orders()
RETURNS JSON AS $$
DECLARE
    v_deadline TIMESTAMPTZ;
    v_payment_deadline TIMESTAMPTZ;
    v_order RECORD;
    v_count INT := 0;
BEGIN
    SELECT value::timestamptz INTO v_deadline FROM edc_config WHERE key = 'modification_deadline';
    IF v_deadline IS NULL THEN
        RETURN json_build_object('error', 'No modification_deadline configured');
    END IF;

    v_payment_deadline := v_deadline + interval '21 days';

    IF now() < v_payment_deadline THEN
        RETURN json_build_object('success', true, 'message', 'Payment deadline has not passed yet', 'cancelled_count', 0);
    END IF;

    FOR v_order IN
        SELECT * FROM edc_orders
        WHERE status IN ('pending', 'awaiting_payment')
    LOOP
        UPDATE edc_orders
        SET status = 'cancelled', updated_at = now()
        WHERE id = v_order.id;

        -- Send cancellation email
        PERFORM send_status_change_email(
            v_order.email,
            v_order.buyer_name,
            v_order.ticket_type,
            'cancelled',
            v_order.id
        );

        v_count := v_count + 1;
    END LOOP;

    RETURN json_build_object('success', true, 'message', v_count || ' order(s) auto-cancelled', 'cancelled_count', v_count);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Schedule cron job to run every hour
--    It's safe to run frequently — it no-ops if the deadline hasn't passed
--    or if there are no orders to cancel.
SELECT cron.unschedule('auto-cancel-expired-orders') WHERE EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'auto-cancel-expired-orders'
);

SELECT cron.schedule(
    'auto-cancel-expired-orders',
    '0 * * * *',  -- every hour on the hour
    $$SELECT auto_cancel_expired_orders()$$
);

-- 5. Update lookup_order to also auto-cancel on lookup (belt and suspenders)
CREATE OR REPLACE FUNCTION lookup_order(
    p_name TEXT,
    p_pin_hash TEXT
) RETURNS JSON AS $$
DECLARE
    v_order edc_orders;
    v_deadline TIMESTAMPTZ;
    v_payment_deadline TIMESTAMPTZ;
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

    -- Auto-cancel if past 21-day payment deadline and still unpaid
    SELECT value::timestamptz INTO v_deadline FROM edc_config WHERE key = 'modification_deadline';
    v_payment_deadline := v_deadline + interval '21 days';

    IF now() > v_payment_deadline AND v_order.status IN ('pending', 'awaiting_payment') THEN
        UPDATE edc_orders
        SET status = 'cancelled', updated_at = now()
        WHERE id = v_order.id;

        -- Send cancellation email
        PERFORM send_status_change_email(
            v_order.email,
            v_order.buyer_name,
            v_order.ticket_type,
            'cancelled',
            v_order.id
        );

        -- Refresh order data after cancellation
        SELECT * INTO v_order FROM edc_orders WHERE id = v_order.id;
    END IF;

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
