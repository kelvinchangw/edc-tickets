-- ============================================
-- EDC Tickets — TEARDOWN
-- Run this in Supabase SQL Editor to remove
-- everything EDC-related from the project.
-- ============================================

-- 1. Drop RPC functions
DROP FUNCTION IF EXISTS submit_order(TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS lookup_order(TEXT, TEXT);
DROP FUNCTION IF EXISTS update_order(TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS cancel_order(TEXT, TEXT);
DROP FUNCTION IF EXISTS save_zelle_screenshot(TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS admin_get_orders(TEXT);
DROP FUNCTION IF EXISTS admin_update_status(TEXT, UUID, TEXT);
DROP FUNCTION IF EXISTS admin_update_config(TEXT, TEXT, TEXT);

-- 2. Drop storage policies
DROP POLICY IF EXISTS "Anyone can upload screenshots" ON storage.objects;
DROP POLICY IF EXISTS "Anyone can upload image screenshots" ON storage.objects;
DROP POLICY IF EXISTS "Anyone can update screenshots" ON storage.objects;
DROP POLICY IF EXISTS "Anyone can view screenshots" ON storage.objects;

-- 3. Delete all files in the bucket, then delete the bucket
DELETE FROM storage.objects WHERE bucket_id = 'edc-zelle-screenshots';
DELETE FROM storage.buckets WHERE id = 'edc-zelle-screenshots';

-- 4. Drop RLS policies
DROP POLICY IF EXISTS "Anyone can read config" ON edc_config;
DROP POLICY IF EXISTS "Anyone can read config (except admin password)" ON edc_config;
DROP POLICY IF EXISTS "Anyone can submit orders" ON edc_orders;

-- 5. Drop tables
DROP TABLE IF EXISTS edc_attempts;
DROP TABLE IF EXISTS edc_orders;
DROP TABLE IF EXISTS edc_config;
