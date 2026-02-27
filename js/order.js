(async () => {
    try {
        const config = await getConfig();
        const ordersOpen = config.orders_open === 'true' && isBeforeDeadline(config.modification_deadline);

        if (!ordersOpen) {
            document.getElementById('loading').style.display = 'none';
            document.getElementById('closed-msg').style.display = 'block';
            return;
        }

        // Build ticket type radio buttons
        const ticketOptions = document.getElementById('ticket-options');
        const types = [
            { value: 'ga', label: 'GA', price: config.ga_price },
            { value: 'ga_plus', label: 'GA+', price: config.ga_plus_price },
            { value: 'vip', label: 'VIP (Rare)', price: config.vip_price }
        ];

        types.forEach((t, i) => {
            const priceLabel = t.price === 'TBD' ? 'TBD' : '$' + t.price;
            const div = document.createElement('div');
            div.className = 'radio-option';
            div.innerHTML = `
                <input type="radio" name="ticket_type" id="ticket-${t.value}" value="${t.value}" ${i === 0 ? 'checked' : ''}>
                <label for="ticket-${t.value}">${t.label} — ${priceLabel}</label>
            `;
            ticketOptions.appendChild(div);
        });

        document.getElementById('loading').style.display = 'none';
        document.getElementById('form-area').style.display = 'block';

        // Form submission
        document.getElementById('order-form').addEventListener('submit', async (e) => {
            e.preventDefault();
            hideMessage('msg');

            const name = document.getElementById('name').value.trim();
            const email = document.getElementById('email').value.trim();
            const pin = document.getElementById('pin').value;
            const pinConfirm = document.getElementById('pin-confirm').value;
            const ticketType = document.querySelector('input[name="ticket_type"]:checked').value;

            // Validation
            if (!name) {
                showMessage('msg', 'Please enter your name', true);
                return;
            }

            if (pin.length < 4 || pin.length > 6) {
                showMessage('msg', 'PIN must be 4-6 digits', true);
                return;
            }

            if (pin !== pinConfirm) {
                showMessage('msg', 'PINs do not match', true);
                return;
            }

            const submitBtn = document.getElementById('submit-btn');
            submitBtn.disabled = true;
            submitBtn.textContent = 'Submitting...';

            try {
                const pinHash = await hashPin(pin);
                const { data, error } = await db.rpc('submit_order', {
                    p_name: name,
                    p_email: email || null,
                    p_pin_hash: pinHash,
                    p_ticket_type: ticketType
                });

                if (error) throw error;

                if (data.error) {
                    showMessage('msg', data.error, true);
                    submitBtn.disabled = false;
                    submitBtn.textContent = 'Submit Order';
                    return;
                }

                // Show success
                const order = data.order;
                document.getElementById('order-summary').innerHTML = `
                    <div class="order-detail">
                        <span class="order-detail-label">Name</span>
                        <span class="order-detail-value">${order.buyer_name}</span>
                    </div>
                    <div class="order-detail">
                        <span class="order-detail-label">Ticket</span>
                        <span class="order-detail-value">${formatTicketType(order.ticket_type)}</span>
                    </div>
                    <div class="order-detail">
                        <span class="order-detail-label">Status</span>
                        <span class="status-badge status-${order.status}">${formatStatus(order.status)}</span>
                    </div>
                `;

                document.getElementById('order-form').style.display = 'none';
                document.getElementById('success-area').style.display = 'block';

            } catch (err) {
                showMessage('msg', 'Something went wrong. Please try again.', true);
                console.error(err);
                submitBtn.disabled = false;
                submitBtn.textContent = 'Submit Order';
            }
        });

    } catch (err) {
        document.getElementById('loading').textContent = 'Failed to load. Please refresh.';
        console.error(err);
    }
})();
