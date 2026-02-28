-- ============================================
-- EDC Tickets — Migration 006: Email notifications via Resend
-- Run this in Supabase SQL Editor
-- ============================================

-- 1. Enable the pg_net extension (async HTTP from PostgreSQL)
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- 2. Add Resend config values
--    IMPORTANT: After running this migration, update resend_api_key and
--    resend_from_email in the edc_config table with your actual values.
INSERT INTO edc_config (key, value) VALUES
    ('resend_api_key', 'CHANGE_ME'),
    ('resend_from_email', 'EDC Tickets <orders@yourdomain.com>'),
    ('resend_enabled', 'true')
ON CONFLICT (key) DO NOTHING;

-- 3. Update RLS policy to also hide resend_api_key from public reads
DROP POLICY IF EXISTS "Anyone can read config (except admin password)" ON edc_config;
CREATE POLICY "Anyone can read non-secret config"
    ON edc_config FOR SELECT
    USING (key NOT IN ('admin_password', 'resend_api_key'));

-- 4. Generic email sender via Resend API
CREATE OR REPLACE FUNCTION send_notification_email(
    p_to_email TEXT,
    p_subject TEXT,
    p_html_body TEXT
) RETURNS void AS $$
DECLARE
    v_api_key TEXT;
    v_from_email TEXT;
    v_enabled TEXT;
    v_request_id BIGINT;
BEGIN
    -- Check kill switch
    SELECT value INTO v_enabled FROM edc_config WHERE key = 'resend_enabled';
    IF v_enabled IS NULL OR v_enabled != 'true' THEN
        RETURN;
    END IF;

    -- Skip if no recipient
    IF p_to_email IS NULL OR trim(p_to_email) = '' THEN
        RETURN;
    END IF;

    -- Get Resend credentials
    SELECT value INTO v_api_key FROM edc_config WHERE key = 'resend_api_key';
    SELECT value INTO v_from_email FROM edc_config WHERE key = 'resend_from_email';

    -- Skip if not configured
    IF v_api_key IS NULL OR v_api_key = 'CHANGE_ME' THEN
        RETURN;
    END IF;

    -- Fire-and-forget HTTP POST to Resend API
    SELECT net.http_post(
        url := 'https://api.resend.com/emails',
        headers := jsonb_build_object(
            'Authorization', 'Bearer ' || v_api_key,
            'Content-Type', 'application/json'
        ),
        body := jsonb_build_object(
            'from', v_from_email,
            'to', jsonb_build_array(p_to_email),
            'subject', p_subject,
            'html', p_html_body
        )
    ) INTO v_request_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Email template: order confirmation
CREATE OR REPLACE FUNCTION send_order_confirmation_email(
    p_email TEXT,
    p_buyer_name TEXT,
    p_ticket_type TEXT,
    p_order_id UUID
) RETURNS void AS $$
DECLARE
    v_event_name TEXT;
    v_ticket_label TEXT;
    v_subject TEXT;
    v_html TEXT;
BEGIN
    IF p_email IS NULL OR trim(p_email) = '' THEN
        RETURN;
    END IF;

    SELECT value INTO v_event_name FROM edc_config WHERE key = 'event_name';
    v_event_name := COALESCE(v_event_name, 'EDC Las Vegas 2026');

    v_ticket_label := CASE p_ticket_type
        WHEN 'ga' THEN 'GA'
        WHEN 'ga_plus' THEN 'GA+'
        WHEN 'vip' THEN 'VIP'
        ELSE p_ticket_type
    END;

    v_subject := v_event_name || ' - Order Confirmed';

    v_html := '<!DOCTYPE html><html><body style="margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,sans-serif;background-color:#0a0a0a;color:#e0e0e0;">'
        || '<div style="max-width:600px;margin:0 auto;padding:40px 20px;">'
        || '<div style="text-align:center;margin-bottom:30px;">'
        || '<h1 style="color:#a855f7;margin:0;font-size:28px;">' || v_event_name || '</h1>'
        || '</div>'
        || '<div style="background-color:#1a1a2e;border-radius:12px;padding:30px;border:1px solid #2a2a4a;">'
        || '<h2 style="margin-top:0;color:#ffffff;">Order Received!</h2>'
        || '<p>Hey ' || p_buyer_name || ',</p>'
        || '<p>Your ticket order has been submitted successfully. Here are the details:</p>'
        || '<div style="background-color:#0f0f23;border-radius:8px;padding:20px;margin:20px 0;">'
        || '<table style="width:100%;border-collapse:collapse;">'
        || '<tr><td style="padding:8px 0;color:#888;">Ticket Type</td><td style="padding:8px 0;text-align:right;font-weight:bold;color:#a855f7;">' || v_ticket_label || '</td></tr>'
        || '<tr><td style="padding:8px 0;color:#888;">Status</td><td style="padding:8px 0;text-align:right;"><span style="background-color:#854d0e;color:#fbbf24;padding:4px 12px;border-radius:999px;font-size:13px;">Pending</span></td></tr>'
        || '<tr><td style="padding:8px 0;color:#888;">Order ID</td><td style="padding:8px 0;text-align:right;font-size:12px;color:#666;">' || p_order_id::text || '</td></tr>'
        || '</table>'
        || '</div>'
        || '<h3 style="color:#ffffff;margin-bottom:8px;">Next Steps</h3>'
        || '<ol style="color:#ccc;line-height:1.8;">'
        || '<li>Wait for payment instructions (you''ll receive another email when your status changes to Awaiting Payment)</li>'
        || '<li>Send Zelle payment and upload the screenshot on the Check Order page</li>'
        || '<li>We''ll verify your payment and fulfill your ticket</li>'
        || '</ol>'
        || '<p style="margin-top:24px;padding-top:16px;border-top:1px solid #2a2a4a;color:#888;font-size:13px;">You can check or modify your order anytime using your name and PIN on the Check Order page.</p>'
        || '</div>'
        || '<p style="text-align:center;margin-top:20px;color:#555;font-size:12px;">This is an automated message. Please do not reply to this email.</p>'
        || '</div></body></html>';

    PERFORM send_notification_email(p_email, v_subject, v_html);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. Email template: status change (admin-triggered)
CREATE OR REPLACE FUNCTION send_status_change_email(
    p_email TEXT,
    p_buyer_name TEXT,
    p_ticket_type TEXT,
    p_new_status TEXT,
    p_order_id UUID
) RETURNS void AS $$
DECLARE
    v_event_name TEXT;
    v_ticket_label TEXT;
    v_status_label TEXT;
    v_status_color TEXT;
    v_status_bg TEXT;
    v_subject TEXT;
    v_message TEXT;
    v_html TEXT;
BEGIN
    IF p_email IS NULL OR trim(p_email) = '' THEN
        RETURN;
    END IF;

    SELECT value INTO v_event_name FROM edc_config WHERE key = 'event_name';
    v_event_name := COALESCE(v_event_name, 'EDC Las Vegas 2026');

    v_ticket_label := CASE p_ticket_type
        WHEN 'ga' THEN 'GA'
        WHEN 'ga_plus' THEN 'GA+'
        WHEN 'vip' THEN 'VIP'
        ELSE p_ticket_type
    END;

    v_status_label := CASE p_new_status
        WHEN 'pending' THEN 'Pending'
        WHEN 'awaiting_payment' THEN 'Awaiting Payment'
        WHEN 'paid' THEN 'Paid'
        WHEN 'verified' THEN 'Verified'
        WHEN 'fulfilled' THEN 'Fulfilled'
        WHEN 'cancelled' THEN 'Cancelled'
        ELSE p_new_status
    END;

    v_status_color := CASE p_new_status
        WHEN 'pending' THEN '#fbbf24'
        WHEN 'awaiting_payment' THEN '#fb923c'
        WHEN 'paid' THEN '#60a5fa'
        WHEN 'verified' THEN '#34d399'
        WHEN 'fulfilled' THEN '#a855f7'
        WHEN 'cancelled' THEN '#f87171'
        ELSE '#888888'
    END;

    v_status_bg := CASE p_new_status
        WHEN 'pending' THEN '#854d0e'
        WHEN 'awaiting_payment' THEN '#7c2d12'
        WHEN 'paid' THEN '#1e3a5f'
        WHEN 'verified' THEN '#064e3b'
        WHEN 'fulfilled' THEN '#3b0764'
        WHEN 'cancelled' THEN '#7f1d1d'
        ELSE '#333333'
    END;

    v_message := CASE p_new_status
        WHEN 'awaiting_payment' THEN
            '<p>Your order is ready for payment. Please send your Zelle payment and then upload a screenshot of the confirmation on the <strong>Check Order</strong> page using your name and PIN.</p>'
        WHEN 'paid' THEN
            '<p>We''ve received your payment submission. We''ll review it shortly and update your status once verified.</p>'
        WHEN 'verified' THEN
            '<p>Your payment has been verified! We''re now processing your ticket. You''ll receive one more update when your ticket is ready.</p>'
        WHEN 'fulfilled' THEN
            '<p>Your ticket is ready! Check the <strong>Check Order</strong> page for delivery details. See you at EDC!</p>'
        WHEN 'cancelled' THEN
            '<p>Your order has been cancelled. If you believe this was done in error, please reach out to us.</p>'
        WHEN 'pending' THEN
            '<p>Your order status has been set back to pending. You''ll receive an update when there''s a change.</p>'
        ELSE
            '<p>Your order status has been updated.</p>'
    END;

    v_subject := v_event_name || ' - Order Update: ' || v_status_label;

    v_html := '<!DOCTYPE html><html><body style="margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,sans-serif;background-color:#0a0a0a;color:#e0e0e0;">'
        || '<div style="max-width:600px;margin:0 auto;padding:40px 20px;">'
        || '<div style="text-align:center;margin-bottom:30px;">'
        || '<h1 style="color:#a855f7;margin:0;font-size:28px;">' || v_event_name || '</h1>'
        || '</div>'
        || '<div style="background-color:#1a1a2e;border-radius:12px;padding:30px;border:1px solid #2a2a4a;">'
        || '<h2 style="margin-top:0;color:#ffffff;">Order Status Update</h2>'
        || '<p>Hey ' || p_buyer_name || ',</p>'
        || '<p>Your order status has been updated:</p>'
        || '<div style="background-color:#0f0f23;border-radius:8px;padding:20px;margin:20px 0;">'
        || '<table style="width:100%;border-collapse:collapse;">'
        || '<tr><td style="padding:8px 0;color:#888;">Ticket Type</td><td style="padding:8px 0;text-align:right;font-weight:bold;color:#a855f7;">' || v_ticket_label || '</td></tr>'
        || '<tr><td style="padding:8px 0;color:#888;">New Status</td><td style="padding:8px 0;text-align:right;"><span style="background-color:' || v_status_bg || ';color:' || v_status_color || ';padding:4px 12px;border-radius:999px;font-size:13px;">' || v_status_label || '</span></td></tr>'
        || '</table>'
        || '</div>'
        || v_message
        || '<p style="margin-top:24px;padding-top:16px;border-top:1px solid #2a2a4a;color:#888;font-size:13px;">You can check your order anytime using your name and PIN on the Check Order page.</p>'
        || '</div>'
        || '<p style="text-align:center;margin-top:20px;color:#555;font-size:12px;">This is an automated message. Please do not reply to this email.</p>'
        || '</div></body></html>';

    PERFORM send_notification_email(p_email, v_subject, v_html);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. Update submit_order to send confirmation email
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

    -- Send confirmation email (async, fire-and-forget)
    PERFORM send_order_confirmation_email(
        v_order.email,
        v_order.buyer_name,
        v_order.ticket_type,
        v_order.id
    );

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

-- 8. Update admin_update_status to send notification email
CREATE OR REPLACE FUNCTION admin_update_status(
    p_password TEXT,
    p_order_id UUID,
    p_status TEXT
) RETURNS JSON AS $$
DECLARE
    v_admin_pw TEXT;
    v_order edc_orders;
BEGIN
    SELECT value INTO v_admin_pw FROM edc_config WHERE key = 'admin_password';
    IF p_password != v_admin_pw THEN
        RETURN json_build_object('error', 'Invalid admin password');
    END IF;

    IF p_status NOT IN ('pending', 'awaiting_payment', 'paid', 'verified', 'fulfilled', 'cancelled') THEN
        RETURN json_build_object('error', 'Invalid status');
    END IF;

    -- Fetch order first (need email and name for notification)
    SELECT * INTO v_order FROM edc_orders WHERE id = p_order_id;

    IF v_order IS NULL THEN
        RETURN json_build_object('error', 'Order not found');
    END IF;

    UPDATE edc_orders
    SET status = p_status, updated_at = now()
    WHERE id = p_order_id;

    -- Send status change email (async, fire-and-forget)
    PERFORM send_status_change_email(
        v_order.email,
        v_order.buyer_name,
        v_order.ticket_type,
        p_status,
        v_order.id
    );

    RETURN json_build_object('success', true, 'message', 'Status updated');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
