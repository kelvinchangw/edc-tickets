const SUPABASE_URL = 'https://njmsbokrtdqthuqimgjb.supabase.co';
const SUPABASE_KEY = 'sb_publishable_F-uLfhubtLf5lPc_Vrx7hw_En8XddCG';

const db = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

async function getConfig() {
    const { data, error } = await db
        .from('edc_config')
        .select('key, value');
    if (error) throw error;
    const config = {};
    data.forEach(row => { config[row.key] = row.value; });
    return config;
}

async function hashPin(pin) {
    const encoder = new TextEncoder();
    const data = encoder.encode(pin);
    const hashBuffer = await crypto.subtle.digest('SHA-256', data);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}

function esc(str) {
    if (!str) return '';
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}

function formatTicketType(type) {
    const labels = { ga: 'GA', ga_plus: 'GA+', vip: 'VIP (Rare)' };
    return labels[type] || type;
}

function formatStatus(status) {
    const labels = {
        pending: 'Pending',
        awaiting_payment: 'Awaiting Payment',
        paid: 'Paid',
        verified: 'Verified',
        fulfilled: 'Fulfilled',
        cancelled: 'Cancelled'
    };
    return labels[status] || status;
}

function formatDate(dateStr) {
    return new Date(dateStr).toLocaleDateString('en-US', {
        month: 'short', day: 'numeric', year: 'numeric',
        hour: 'numeric', minute: '2-digit'
    });
}

function isBeforeDeadline(deadline) {
    return new Date() < new Date(deadline);
}

function showMessage(containerId, message, isError = false) {
    const el = document.getElementById(containerId);
    el.textContent = message;
    el.className = isError ? 'message error' : 'message success';
    el.style.display = 'block';
}

function hideMessage(containerId) {
    const el = document.getElementById(containerId);
    el.style.display = 'none';
}

// Clear invalid state on input
document.addEventListener('input', (e) => {
    if (e.target.classList.contains('invalid')) {
        e.target.classList.remove('invalid');
    }
});
