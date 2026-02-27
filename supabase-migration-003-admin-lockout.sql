-- ============================================
-- EDC Tickets — Migration 003: Revert admin lockout
-- Run this in Supabase SQL Editor
-- ============================================

-- Restore admin_get_orders without lockout
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
