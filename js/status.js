let currentOrder = null;
let currentPinHash = null;
let currentName = null;
let selectedFile = null;
let paymentCountdownInterval = null;

// Lookup form
document.getElementById('lookup-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    hideMessage('msg');

    const firstName = document.getElementById('first-name').value.trim();
    const lastName = document.getElementById('last-name').value.trim();
    const pin = document.getElementById('pin').value;

    // Clear previous validation
    document.querySelectorAll('.invalid').forEach(el => el.classList.remove('invalid'));

    let hasError = false;
    if (!firstName) { document.getElementById('first-name').classList.add('invalid'); hasError = true; }
    if (!lastName) { document.getElementById('last-name').classList.add('invalid'); hasError = true; }
    if (!pin) { document.getElementById('pin').classList.add('invalid'); hasError = true; }

    if (hasError) {
        showMessage('msg', 'Please fill in all fields', true);
        return;
    }

    const name = firstName + ' ' + lastName;

    const btn = document.getElementById('lookup-btn');
    btn.disabled = true;
    btn.textContent = 'Looking up...';

    try {
        const pinHash = await hashPin(pin);
        const { data, error } = await db.rpc('lookup_order', {
            p_name: name,
            p_pin_hash: pinHash
        });

        if (error) throw error;

        if (data.error) {
            let msg = data.error;
            if (data.attempts_remaining !== undefined && data.attempts_remaining > 0) {
                msg += ` (${data.attempts_remaining} attempt${data.attempts_remaining === 1 ? '' : 's'} remaining)`;
            }
            showMessage('msg', msg, true);
            if (data.locked) {
                btn.disabled = true;
                btn.textContent = 'Locked';
            } else {
                btn.disabled = false;
                btn.textContent = 'Look Up Order';
            }
            return;
        }

        currentOrder = data.order;
        currentPinHash = pinHash;
        currentName = name;
        renderOrder(data);

    } catch (err) {
        showMessage('msg', 'Something went wrong. Please try again.', true);
        console.error(err);
        btn.disabled = false;
        btn.textContent = 'Look Up Order';
    }
});

async function renderOrder(data) {
    const order = data.order;
    const canModify = data.can_modify;

    // Clear any previous countdown
    if (paymentCountdownInterval) {
        clearInterval(paymentCountdownInterval);
        paymentCountdownInterval = null;
    }

    // Build payment deadline info for awaiting_payment orders
    let paymentDeadlineHtml = '';
    let paymentDeadline = null;
    if (order.status === 'awaiting_payment') {
        const config = await getConfig();
        const submissionDeadline = new Date(config.modification_deadline);
        paymentDeadline = new Date(submissionDeadline.getTime() + 21 * 24 * 60 * 60 * 1000);
        const now = new Date();
        const expired = now >= paymentDeadline;

        if (expired) {
            paymentDeadlineHtml = `
            <div class="payment-notice" style="margin-top:1.25rem;padding:1rem 1.25rem;background:rgba(255,34,85,0.1);border:1px solid rgba(255,34,85,0.3);border-radius:10px;">
                <p style="margin:0 0 0.5rem 0;color:var(--error);font-weight:600;">Payment Deadline Expired</p>
                <p style="margin:0;color:#ccc;font-size:0.9rem;">The 21-day payment window has passed. Your order will be cancelled.</p>
            </div>`;
        } else {
            paymentDeadlineHtml = `
            <div class="payment-notice" style="margin-top:1.25rem;padding:1rem 1.25rem;background:rgba(251,146,60,0.1);border:1px solid rgba(251,146,60,0.3);border-radius:10px;">
                <p style="margin:0 0 0.5rem 0;color:#fb923c;font-weight:600;">Payment Instructions</p>
                <p style="margin:0 0 1rem 0;color:#ccc;font-size:0.9rem;">Please send your Zelle payment to <strong style="color:#fff;">(702) 330-7976</strong> and upload a screenshot below as proof of payment.</p>
                <p style="margin:0 0 0.5rem 0;color:var(--error);font-weight:600;font-size:0.8rem;">Payment Deadline: ${paymentDeadline.toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' })} at ${paymentDeadline.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })}</p>
                <div class="countdown" id="payment-countdown">
                    <div class="countdown-segment" style="background:rgba(255,34,85,0.06);border-color:rgba(255,34,85,0.2);">
                        <div class="countdown-number" style="color:var(--error);" id="pay-days">--</div>
                        <div class="countdown-label">Days</div>
                    </div>
                    <div class="countdown-segment" style="background:rgba(255,34,85,0.06);border-color:rgba(255,34,85,0.2);">
                        <div class="countdown-number" style="color:var(--error);" id="pay-hours">--</div>
                        <div class="countdown-label">Hours</div>
                    </div>
                    <div class="countdown-segment" style="background:rgba(255,34,85,0.06);border-color:rgba(255,34,85,0.2);">
                        <div class="countdown-number" style="color:var(--error);" id="pay-mins">--</div>
                        <div class="countdown-label">Mins</div>
                    </div>
                    <div class="countdown-segment" style="background:rgba(255,34,85,0.06);border-color:rgba(255,34,85,0.2);">
                        <div class="countdown-number" style="color:var(--error);" id="pay-secs">--</div>
                        <div class="countdown-label">Secs</div>
                    </div>
                </div>
            </div>`;
        }
    }

    // Order details
    document.getElementById('order-details').innerHTML = `
        <div class="order-detail">
            <span class="order-detail-label">Name</span>
            <span class="order-detail-value">${esc(order.buyer_name)}</span>
        </div>
        <div class="order-detail">
            <span class="order-detail-label">Ticket</span>
            <span class="order-detail-value">${formatTicketType(order.ticket_type)}</span>
        </div>
        <div class="order-detail">
            <span class="order-detail-label">Status</span>
            <span class="status-badge status-${order.status}">${formatStatus(order.status)}</span>
        </div>
        <div class="order-detail">
            <span class="order-detail-label">Submitted</span>
            <span class="order-detail-value">${formatDate(order.created_at)}</span>
        </div>
        ${order.updated_at !== order.created_at ? `
        <div class="order-detail">
            <span class="order-detail-label">Last Updated</span>
            <span class="order-detail-value">${formatDate(order.updated_at)}</span>
        </div>
        ` : ''}
        ${paymentDeadlineHtml}
    `;

    // Start live countdown if awaiting payment and not expired
    if (paymentDeadline && document.getElementById('payment-countdown')) {
        function updatePaymentCountdown() {
            const now = new Date();
            const diff = paymentDeadline - now;
            if (diff <= 0) {
                clearInterval(paymentCountdownInterval);
                document.getElementById('pay-days').textContent = '00';
                document.getElementById('pay-hours').textContent = '00';
                document.getElementById('pay-mins').textContent = '00';
                document.getElementById('pay-secs').textContent = '00';
                return;
            }
            document.getElementById('pay-days').textContent = String(Math.floor(diff / 86400000)).padStart(2, '0');
            document.getElementById('pay-hours').textContent = String(Math.floor((diff % 86400000) / 3600000)).padStart(2, '0');
            document.getElementById('pay-mins').textContent = String(Math.floor((diff % 3600000) / 60000)).padStart(2, '0');
            document.getElementById('pay-secs').textContent = String(Math.floor((diff % 60000) / 1000)).padStart(2, '0');
        }

        updatePaymentCountdown();
        paymentCountdownInterval = setInterval(updatePaymentCountdown, 1000);
    }

    // Screenshot section - always show so they can upload Zelle proof
    const screenshotSection = document.getElementById('screenshot-section');
    const existingScreenshot = document.getElementById('existing-screenshot');

    if (order.zelle_screenshot_url) {
        const publicUrl = `${SUPABASE_URL}/storage/v1/object/public/edc-zelle-screenshots/${order.zelle_screenshot_url}`;
        existingScreenshot.innerHTML = `
            <div class="screenshot-preview">
                <img src="${publicUrl}" alt="Zelle screenshot">
            </div>
            <p style="margin-top:0.75rem; font-size:0.85rem">Upload a new screenshot to replace:</p>
        `;
    } else {
        existingScreenshot.innerHTML = '';
    }
    screenshotSection.style.display = order.status !== 'cancelled' ? 'block' : 'none';

    // Modify section
    const modifySection = document.getElementById('modify-section');
    if (canModify) {
        modifySection.style.display = 'block';
        buildModifyOptions(order.ticket_type);
    } else {
        modifySection.style.display = 'none';
    }

    // Show order area, hide lookup
    document.getElementById('lookup-area').style.display = 'none';
    document.getElementById('order-area').style.display = 'block';
}

async function buildModifyOptions(currentType) {
    const config = await getConfig();
    const ticketOptions = document.getElementById('modify-ticket-options');
    ticketOptions.innerHTML = '';

    const types = [
        { value: 'ga', label: 'GA', price: config.ga_price },
        { value: 'ga_plus', label: 'GA+', price: config.ga_plus_price },
    ];

    types.forEach(t => {
        const priceLabel = t.price === 'TBD' ? 'TBD' : '$' + t.price;
        const div = document.createElement('div');
        div.className = 'radio-option';
        div.innerHTML = `
            <input type="radio" name="modify_ticket_type" id="modify-${t.value}" value="${t.value}" ${t.value === currentType ? 'checked' : ''}>
            <label for="modify-${t.value}">${t.label}<span class="radio-price">${priceLabel}</span></label>
        `;
        ticketOptions.appendChild(div);
    });
}

// File upload handling
document.getElementById('file-drop').addEventListener('click', () => {
    document.getElementById('screenshot-input').click();
});

document.getElementById('screenshot-input').addEventListener('change', (e) => {
    selectedFile = e.target.files[0];
    if (selectedFile) {
        document.querySelector('.file-upload-label').innerHTML = `Selected: <span>${selectedFile.name}</span>`;
        document.getElementById('upload-btn').style.display = 'block';
    }
});

// Upload screenshot
document.getElementById('upload-btn').addEventListener('click', async () => {
    if (!selectedFile || !currentOrder) return;

    const btn = document.getElementById('upload-btn');
    btn.disabled = true;
    btn.textContent = 'Uploading...';

    try {
        const ext = selectedFile.name.split('.').pop();
        const filePath = `${currentOrder.id}.${ext}`;

        const { error: uploadError } = await db.storage
            .from('edc-zelle-screenshots')
            .upload(filePath, selectedFile, { upsert: true });

        if (uploadError) throw uploadError;

        // Save path to order
        const { data, error } = await db.rpc('save_zelle_screenshot', {
            p_name: currentName,
            p_pin_hash: currentPinHash,
            p_screenshot_url: filePath
        });

        if (error) throw error;
        if (data.error) {
            showMessage('msg', data.error, true);
            btn.disabled = false;
            btn.textContent = 'Upload Screenshot';
            return;
        }

        showMessage('msg', 'Screenshot uploaded!', false);
        // Refresh order display
        const refreshed = await db.rpc('lookup_order', {
            p_name: currentName,
            p_pin_hash: currentPinHash
        });
        if (refreshed.data && refreshed.data.order) {
            currentOrder = refreshed.data.order;
            renderOrder(refreshed.data);
        }
        selectedFile = null;
        btn.disabled = false;
        btn.textContent = 'Upload Screenshot';

    } catch (err) {
        showMessage('msg', 'Upload failed. Please try again.', true);
        console.error(err);
        btn.disabled = false;
        btn.textContent = 'Upload Screenshot';
    }
});

// Save changes (ticket type)
document.getElementById('save-btn').addEventListener('click', async () => {
    const newType = document.querySelector('input[name="modify_ticket_type"]:checked').value;
    const btn = document.getElementById('save-btn');
    btn.disabled = true;
    btn.textContent = 'Saving...';
    hideMessage('msg');

    try {
        const { data, error } = await db.rpc('update_order', {
            p_name: currentName,
            p_pin_hash: currentPinHash,
            p_ticket_type: newType
        });

        if (error) throw error;
        if (data.error) {
            showMessage('msg', data.error, true);
            btn.disabled = false;
            btn.textContent = 'Save Changes';
            return;
        }

        showMessage('msg', 'Order updated!', false);
        // Refresh
        const refreshed = await db.rpc('lookup_order', {
            p_name: currentName,
            p_pin_hash: currentPinHash
        });
        if (refreshed.data && refreshed.data.order) {
            currentOrder = refreshed.data.order;
            renderOrder(refreshed.data);
        }

    } catch (err) {
        showMessage('msg', 'Update failed. Please try again.', true);
        console.error(err);
    }

    btn.disabled = false;
    btn.textContent = 'Save Changes';
});

// Cancel order
document.getElementById('cancel-btn').addEventListener('click', async () => {
    if (!confirm('Are you sure you want to cancel your order? This cannot be undone.')) return;

    const btn = document.getElementById('cancel-btn');
    btn.disabled = true;
    btn.textContent = 'Cancelling...';
    hideMessage('msg');

    try {
        const { data, error } = await db.rpc('cancel_order', {
            p_name: currentName,
            p_pin_hash: currentPinHash
        });

        if (error) throw error;
        if (data.error) {
            showMessage('msg', data.error, true);
            btn.disabled = false;
            btn.textContent = 'Cancel Order';
            return;
        }

        showMessage('msg', 'Order cancelled.', false);
        // Refresh
        const refreshed = await db.rpc('lookup_order', {
            p_name: currentName,
            p_pin_hash: currentPinHash
        });
        if (refreshed.data && refreshed.data.order) {
            currentOrder = refreshed.data.order;
            renderOrder(refreshed.data);
        } else {
            // Order is cancelled, go back to lookup
            document.getElementById('order-area').style.display = 'none';
            document.getElementById('lookup-area').style.display = 'block';
        }

    } catch (err) {
        showMessage('msg', 'Cancel failed. Please try again.', true);
        console.error(err);
        btn.disabled = false;
        btn.textContent = 'Cancel Order';
    }
});

// Back button
document.getElementById('back-btn').addEventListener('click', () => {
    if (paymentCountdownInterval) {
        clearInterval(paymentCountdownInterval);
        paymentCountdownInterval = null;
    }
    document.getElementById('order-area').style.display = 'none';
    document.getElementById('lookup-area').style.display = 'block';
    document.getElementById('first-name').value = '';
    document.getElementById('last-name').value = '';
    document.getElementById('pin').value = '';
    document.getElementById('lookup-btn').disabled = false;
    document.getElementById('lookup-btn').textContent = 'Look Up Order';
    hideMessage('msg');
    currentOrder = null;
    currentPinHash = null;
    currentName = null;
    selectedFile = null;
});
