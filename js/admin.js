let adminPassword = null;
let allOrders = [];

// Login
document.getElementById('login-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    hideMessage('msg');

    const rawPassword = document.getElementById('admin-pw').value;
    adminPassword = await hashPin(rawPassword);

    try {
        const { data, error } = await db.rpc('admin_get_orders', {
            p_password: adminPassword
        });

        if (error) throw error;
        if (data.error) {
            showMessage('msg', data.error, true);
            adminPassword = null;
            return;
        }

        allOrders = data.orders || [];
        document.getElementById('login-area').style.display = 'none';
        document.getElementById('dashboard').style.display = 'block';
        loadConfig();
        renderDashboard();

    } catch (err) {
        showMessage('msg', 'Login failed. Please try again.', true);
        console.error(err);
        adminPassword = null;
    }
});

// Load config into settings form
async function loadConfig() {
    try {
        const config = await getConfig();
        document.getElementById('config-orders-open').value = config.orders_open;
        document.getElementById('config-ga-price').value = config.ga_price || '';
        document.getElementById('config-ga-plus-price').value = config.ga_plus_price || '';
        document.getElementById('config-vip-price').value = config.vip_price || '';
    } catch (err) {
        console.error('Failed to load config:', err);
    }
}

function renderDashboard() {
    const statusFilter = document.getElementById('filter-status').value;
    const typeFilter = document.getElementById('filter-type').value;

    let filtered = allOrders;
    if (statusFilter) filtered = filtered.filter(o => o.status === statusFilter);
    if (typeFilter) filtered = filtered.filter(o => o.ticket_type === typeFilter);

    // Stats (from all orders, not filtered)
    const nonCancelled = allOrders.filter(o => o.status !== 'cancelled');
    const stats = {
        total: nonCancelled.length,
        ga: nonCancelled.filter(o => o.ticket_type === 'ga').length,
        ga_plus: nonCancelled.filter(o => o.ticket_type === 'ga_plus').length,
        vip: nonCancelled.filter(o => o.ticket_type === 'vip').length,
        pending: nonCancelled.filter(o => o.status === 'pending').length,
        paid: nonCancelled.filter(o => o.status === 'paid').length,
        fulfilled: nonCancelled.filter(o => o.status === 'fulfilled').length
    };

    document.getElementById('stats').innerHTML = `
        <div class="stat-card">
            <div class="stat-number">${stats.total}</div>
            <div class="stat-label">Total</div>
        </div>
        <div class="stat-card">
            <div class="stat-number">${stats.ga}</div>
            <div class="stat-label">GA</div>
        </div>
        <div class="stat-card">
            <div class="stat-number">${stats.ga_plus}</div>
            <div class="stat-label">GA+</div>
        </div>
        <div class="stat-card">
            <div class="stat-number">${stats.vip}</div>
            <div class="stat-label">VIP</div>
        </div>
        <div class="stat-card">
            <div class="stat-number">${stats.pending}</div>
            <div class="stat-label">Pending</div>
        </div>
        <div class="stat-card">
            <div class="stat-number">${stats.paid}</div>
            <div class="stat-label">Paid</div>
        </div>
        <div class="stat-card">
            <div class="stat-number">${stats.fulfilled}</div>
            <div class="stat-label">Fulfilled</div>
        </div>
    `;

    // Orders table
    const tbody = document.getElementById('orders-body');
    const noOrders = document.getElementById('no-orders');

    if (filtered.length === 0) {
        tbody.innerHTML = '';
        noOrders.style.display = 'block';
        return;
    }

    noOrders.style.display = 'none';

    tbody.innerHTML = filtered.map(order => {
        const screenshotLink = order.zelle_screenshot_url
            ? `<a href="${SUPABASE_URL}/storage/v1/object/public/edc-zelle-screenshots/${encodeURI(order.zelle_screenshot_url)}" target="_blank" class="screenshot-link">View</a>`
            : '—';

        return `
            <tr>
                <td><strong>${esc(order.buyer_name)}</strong></td>
                <td>${esc(order.email) || '—'}</td>
                <td>${formatTicketType(order.ticket_type)}</td>
                <td>
                    <select onchange="updateStatus('${order.id}', this.value)" data-order-id="${order.id}">
                        ${['pending', 'confirmed', 'paid', 'fulfilled', 'cancelled'].map(s =>
                            `<option value="${s}" ${s === order.status ? 'selected' : ''}>${formatStatus(s)}</option>`
                        ).join('')}
                    </select>
                </td>
                <td>${screenshotLink}</td>
                <td>${formatDate(order.created_at)}</td>
            </tr>
        `;
    }).join('');
}

// Update order status
async function updateStatus(orderId, newStatus) {
    try {
        const { data, error } = await db.rpc('admin_update_status', {
            p_password: adminPassword,
            p_order_id: orderId,
            p_status: newStatus
        });

        if (error) throw error;
        if (data.error) {
            showMessage('msg', data.error, true);
            return;
        }

        // Update local data
        const order = allOrders.find(o => o.id === orderId);
        if (order) order.status = newStatus;
        renderDashboard();
        showMessage('msg', `Status updated to ${formatStatus(newStatus)}`, false);

    } catch (err) {
        showMessage('msg', 'Failed to update status', true);
        console.error(err);
    }
}

// Filters
document.getElementById('filter-status').addEventListener('change', renderDashboard);
document.getElementById('filter-type').addEventListener('change', renderDashboard);

// Save config
document.getElementById('save-config-btn').addEventListener('click', async () => {
    const btn = document.getElementById('save-config-btn');
    btn.disabled = true;
    btn.textContent = 'Saving...';
    hideMessage('msg');

    const updates = [
        { key: 'orders_open', value: document.getElementById('config-orders-open').value },
        { key: 'ga_price', value: document.getElementById('config-ga-price').value || 'TBD' },
        { key: 'ga_plus_price', value: document.getElementById('config-ga-plus-price').value || 'TBD' },
        { key: 'vip_price', value: document.getElementById('config-vip-price').value || 'TBD' }
    ];

    try {
        for (const u of updates) {
            const { data, error } = await db.rpc('admin_update_config', {
                p_password: adminPassword,
                p_key: u.key,
                p_value: u.value
            });
            if (error) throw error;
            if (data.error) throw new Error(data.error);
        }

        showMessage('msg', 'Settings saved', false);
    } catch (err) {
        showMessage('msg', 'Failed to save settings', true);
        console.error(err);
    }

    btn.disabled = false;
    btn.textContent = 'Save Settings';
});

// Refresh orders
async function refreshOrders() {
    try {
        const { data, error } = await db.rpc('admin_get_orders', {
            p_password: adminPassword
        });
        if (error) throw error;
        if (data.error) return;
        allOrders = data.orders || [];
        renderDashboard();
    } catch (err) {
        console.error('Refresh failed:', err);
    }
}

// Auto-refresh every 30 seconds
setInterval(refreshOrders, 30000);

// Logout
document.getElementById('logout-btn').addEventListener('click', () => {
    adminPassword = null;
    allOrders = [];
    document.getElementById('dashboard').style.display = 'none';
    document.getElementById('login-area').style.display = 'block';
    document.getElementById('admin-pw').value = '';
    hideMessage('msg');
});
