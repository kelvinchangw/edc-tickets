-- ============================================
-- EDC Tickets — Supabase Migration
-- Run this in Supabase SQL Editor
-- ============================================

-- 1. Config table
CREATE TABLE edc_config (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

ALTER TABLE edc_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can read config"
    ON edc_config FOR SELECT
    USING (true);

-- Seed config
INSERT INTO edc_config (key, value) VALUES
    ('ga_price', 'TBD'),
    ('ga_plus_price', 'TBD'),
    ('vip_price', 'TBD'),
    ('modification_deadline', '2026-03-07T21:00:00-07:00'),
    ('admin_password', 'CHANGE_ME'),
    ('orders_open', 'true'),
    ('event_name', 'EDC Las Vegas 2026');

-- 2. Orders table
CREATE TABLE edc_orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    buyer_name TEXT NOT NULL,
    email TEXT,
    pin_hash TEXT NOT NULL,
    ticket_type TEXT NOT NULL CHECK (ticket_type IN ('ga', 'ga_plus', 'vip')),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'paid', 'fulfilled', 'cancelled')),
    zelle_screenshot_url TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE edc_orders ENABLE ROW LEVEL SECURITY;

-- Allow anyone to insert new orders
CREATE POLICY "Anyone can submit orders"
    ON edc_orders FOR INSERT
    WITH CHECK (true);

-- No direct SELECT/UPDATE/DELETE — everything goes through RPC functions
-- This prevents anyone from reading all orders via the anon key

-- 3. RPC Functions

-- Submit order (with duplicate check)
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
    -- Check if orders are open
    SELECT (value = 'true') INTO v_orders_open FROM edc_config WHERE key = 'orders_open';
    IF NOT v_orders_open THEN
        RETURN json_build_object('error', 'Orders are currently closed');
    END IF;

    -- Check deadline
    SELECT value::timestamptz INTO v_deadline FROM edc_config WHERE key = 'modification_deadline';
    IF now() > v_deadline THEN
        RETURN json_build_object('error', 'The order deadline has passed');
    END IF;

    -- Check for existing order with same name
    SELECT id INTO v_existing FROM edc_orders
        WHERE lower(trim(buyer_name)) = lower(trim(p_name))
        AND status != 'cancelled';
    IF v_existing IS NOT NULL THEN
        RETURN json_build_object('error', 'An order already exists for this name. Use Check Order to modify it.');
    END IF;

    -- Insert
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

-- Lookup order by name + pin
CREATE OR REPLACE FUNCTION lookup_order(
    p_name TEXT,
    p_pin_hash TEXT
) RETURNS JSON AS $$
DECLARE
    v_order edc_orders;
    v_deadline TIMESTAMPTZ;
    v_can_modify BOOLEAN;
    v_screenshot_url TEXT;
BEGIN
    SELECT * INTO v_order FROM edc_orders
        WHERE lower(trim(buyer_name)) = lower(trim(p_name))
        AND pin_hash = p_pin_hash
        AND status != 'cancelled';

    IF v_order IS NULL THEN
        RETURN json_build_object('error', 'No order found. Check your name and PIN.');
    END IF;

    SELECT value::timestamptz INTO v_deadline FROM edc_config WHERE key = 'modification_deadline';
    v_can_modify := now() < v_deadline AND v_order.status IN ('pending', 'confirmed');

    -- Get screenshot public URL if exists
    v_screenshot_url := v_order.zelle_screenshot_url;

    RETURN json_build_object(
        'success', true,
        'order', json_build_object(
            'id', v_order.id,
            'buyer_name', v_order.buyer_name,
            'email', v_order.email,
            'ticket_type', v_order.ticket_type,
            'status', v_order.status,
            'zelle_screenshot_url', v_screenshot_url,
            'created_at', v_order.created_at,
            'updated_at', v_order.updated_at
        ),
        'can_modify', v_can_modify,
        'deadline', v_deadline
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Update order (change ticket type)
CREATE OR REPLACE FUNCTION update_order(
    p_name TEXT,
    p_pin_hash TEXT,
    p_ticket_type TEXT
) RETURNS JSON AS $$
DECLARE
    v_order edc_orders;
    v_deadline TIMESTAMPTZ;
BEGIN
    SELECT value::timestamptz INTO v_deadline FROM edc_config WHERE key = 'modification_deadline';
    IF now() > v_deadline THEN
        RETURN json_build_object('error', 'The modification deadline has passed');
    END IF;

    SELECT * INTO v_order FROM edc_orders
        WHERE lower(trim(buyer_name)) = lower(trim(p_name))
        AND pin_hash = p_pin_hash
        AND status IN ('pending', 'confirmed');

    IF v_order IS NULL THEN
        RETURN json_build_object('error', 'No modifiable order found');
    END IF;

    UPDATE edc_orders
    SET ticket_type = p_ticket_type, updated_at = now()
    WHERE id = v_order.id;

    RETURN json_build_object('success', true, 'message', 'Order updated');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Cancel order
CREATE OR REPLACE FUNCTION cancel_order(
    p_name TEXT,
    p_pin_hash TEXT
) RETURNS JSON AS $$
DECLARE
    v_order edc_orders;
    v_deadline TIMESTAMPTZ;
BEGIN
    SELECT value::timestamptz INTO v_deadline FROM edc_config WHERE key = 'modification_deadline';
    IF now() > v_deadline THEN
        RETURN json_build_object('error', 'The modification deadline has passed');
    END IF;

    SELECT * INTO v_order FROM edc_orders
        WHERE lower(trim(buyer_name)) = lower(trim(p_name))
        AND pin_hash = p_pin_hash
        AND status IN ('pending', 'confirmed');

    IF v_order IS NULL THEN
        RETURN json_build_object('error', 'No cancellable order found');
    END IF;

    UPDATE edc_orders
    SET status = 'cancelled', updated_at = now()
    WHERE id = v_order.id;

    RETURN json_build_object('success', true, 'message', 'Order cancelled');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Save Zelle screenshot URL
CREATE OR REPLACE FUNCTION save_zelle_screenshot(
    p_name TEXT,
    p_pin_hash TEXT,
    p_screenshot_url TEXT
) RETURNS JSON AS $$
DECLARE
    v_order edc_orders;
BEGIN
    SELECT * INTO v_order FROM edc_orders
        WHERE lower(trim(buyer_name)) = lower(trim(p_name))
        AND pin_hash = p_pin_hash
        AND status != 'cancelled';

    IF v_order IS NULL THEN
        RETURN json_build_object('error', 'No order found');
    END IF;

    UPDATE edc_orders
    SET zelle_screenshot_url = p_screenshot_url, updated_at = now()
    WHERE id = v_order.id;

    RETURN json_build_object('success', true, 'message', 'Screenshot saved');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Admin: get all orders (password protected)
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

-- Admin: update order status
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

    UPDATE edc_orders
    SET status = p_status, updated_at = now()
    WHERE id = p_order_id;

    IF NOT FOUND THEN
        RETURN json_build_object('error', 'Order not found');
    END IF;

    RETURN json_build_object('success', true, 'message', 'Status updated');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Admin: update config values
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

    UPDATE edc_config SET value = p_value WHERE key = p_key;

    IF NOT FOUND THEN
        RETURN json_build_object('error', 'Config key not found');
    END IF;

    RETURN json_build_object('success', true, 'message', 'Config updated');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Storage bucket for Zelle screenshots
INSERT INTO storage.buckets (id, name, public)
VALUES ('edc-zelle-screenshots', 'edc-zelle-screenshots', true)
ON CONFLICT (id) DO NOTHING;

-- Allow anyone to upload to the bucket
CREATE POLICY "Anyone can upload screenshots"
    ON storage.objects FOR INSERT
    WITH CHECK (bucket_id = 'edc-zelle-screenshots');

-- Allow anyone to read screenshots (public bucket)
CREATE POLICY "Anyone can view screenshots"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'edc-zelle-screenshots');
