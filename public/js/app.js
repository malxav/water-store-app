const peso = n => '₱' + Number(n || 0).toFixed(2);

// ---------- Tab switching ----------
document.querySelectorAll('.tab-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
    btn.classList.add('active');
    document.getElementById('tab-' + btn.dataset.tab).classList.add('active');
    if (btn.dataset.tab === 'customers') loadCustomerTable(1);
    if (btn.dataset.tab === 'debts') loadDebts(1);
    if (btn.dataset.tab === 'history') { loadHistory(1); loadPoints(1); }
  });
});

let allCustomers = [];
let items = [];
let currentPriceList = [];

async function loadCustomers() {
  allCustomers = await fetch('/api/customers/all').then(r => r.json());
  const selects = ['sale-customer', 'deposit-customer', 'balance-customer'];
  selects.forEach(id => {
    const el = document.getElementById(id);
    el.innerHTML = allCustomers.map(c => `<option value="${c.CustomerID}">${c.CustomerID === 0 ? 'Walk-in / Unregistered' : c.CustomerName} ${c.CustomerSegment === 'PDAO' ? '(PDAO)' : ''}</option>`).join('');
  });
}

async function loadItems() {
  items = await fetch('/api/items').then(r => r.json());
}

async function loadPriceReference() {
  const custId = document.getElementById('sale-customer').value;
  const cust = allCustomers.find(c => c.CustomerID == custId);
  const segment = cust ? cust.CustomerSegment : 'Regular';
  currentPriceList = await fetch('/api/pricelist?segment=' + segment).then(r => r.json());

  const tbody = document.querySelector('#price-reference tbody');
  tbody.innerHTML = currentPriceList.map(p =>
    `<tr><td>${p.ItemName}</td><td class="mono">${peso(p.UnitPrice)}</td></tr>`
  ).join('');

  refreshLineSelects();
  recalcTotal();
}

// ---------- Order line builder ----------
function lineRowHTML() {
  const options = items.map(i => `<option value="${i.ItemID}">${i.ItemName}</option>`).join('');
  return `<div class="line-row">
    <select class="line-item">${options}</select>
    <input type="number" class="line-qty" min="1" value="1">
    <button type="button" class="line-remove">×</button>
  </div>`;
}

function addLine() {
  const wrap = document.getElementById('sale-lines');
  const div = document.createElement('div');
  div.innerHTML = lineRowHTML();
  const row = div.firstElementChild;
  wrap.appendChild(row);
  row.querySelector('.line-remove').addEventListener('click', () => { row.remove(); recalcTotal(); });
  row.querySelector('.line-item').addEventListener('change', recalcTotal);
  row.querySelector('.line-qty').addEventListener('input', recalcTotal);
  recalcTotal();
}

function refreshLineSelects() {
  document.querySelectorAll('.line-item').forEach(sel => {
    const current = sel.value;
    sel.innerHTML = items.map(i => `<option value="${i.ItemID}">${i.ItemName}</option>`).join('');
    sel.value = current;
  });
}

function recalcTotal() {
  let subtotal = 0;
  document.querySelectorAll('.line-row').forEach(row => {
    const itemId = row.querySelector('.line-item').value;
    const qty = parseInt(row.querySelector('.line-qty').value || '0', 10);
    const price = currentPriceList.find(p => p.ItemID == itemId);
    if (price) subtotal += price.UnitPrice * qty;
  });
  const shipping = document.getElementById('sale-shipping').checked ? 30 : 0;
  document.getElementById('sale-subtotal').textContent = peso(subtotal);
  document.getElementById('sale-shipfee').textContent = peso(shipping);
  document.getElementById('sale-total').textContent = peso(subtotal + shipping);
}

document.getElementById('add-line').addEventListener('click', addLine);
document.getElementById('sale-customer').addEventListener('change', loadPriceReference);
document.getElementById('sale-shipping').addEventListener('change', recalcTotal);

document.getElementById('submit-sale').addEventListener('click', async () => {
  const feedback = document.getElementById('sale-feedback');
  feedback.className = 'feedback';
  feedback.textContent = '';

  const lines = [...document.querySelectorAll('.line-row')].map(row => ({
    itemId: parseInt(row.querySelector('.line-item').value, 10),
    quantity: parseInt(row.querySelector('.line-qty').value, 10)
  }));

  const body = {
    customerId: parseInt(document.getElementById('sale-customer').value, 10),
    nameOnRecord: document.getElementById('sale-name').value.trim(),
    fundingType: document.getElementById('sale-funding').value,
    shippingFlag: document.getElementById('sale-shipping').checked,
    lines
  };

  if (!body.nameOnRecord) { feedback.className = 'feedback err'; feedback.textContent = 'Please enter the name on record.'; return; }
  if (lines.length === 0) { feedback.className = 'feedback err'; feedback.textContent = 'Add at least one item.'; return; }

  try {
    const res = await fetch('/api/transactions', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'Something went wrong.');

    feedback.className = 'feedback ok';
    feedback.textContent = `Sale #${data.TransactionID} completed — total ${peso(data.TotalAmount)}.`;

    document.getElementById('sale-lines').innerHTML = '';
    addLine();
    document.getElementById('sale-name').value = '';
    document.getElementById('sale-shipping').checked = false;
    recalcTotal();
  } catch (err) {
    feedback.className = 'feedback err';
    feedback.textContent = err.message;
  }
});

// ---------- Pagination helper ----------
function renderPagination(containerId, total, page, pageSize, onGoto) {
  const container = document.getElementById(containerId);
  const totalPages = Math.max(Math.ceil(total / pageSize), 1);
  if (total <= pageSize) { container.innerHTML = ''; return; }
  container.innerHTML = `
    <button id="${containerId}-prev" ${page <= 1 ? 'disabled' : ''}>‹ Prev</button>
    <span>Page ${page} of ${totalPages} (${total} total)</span>
    <button id="${containerId}-next" ${page >= totalPages ? 'disabled' : ''}>Next ›</button>
  `;
  document.getElementById(`${containerId}-prev`).addEventListener('click', () => onGoto(page - 1));
  document.getElementById(`${containerId}-next`).addEventListener('click', () => onGoto(page + 1));
}

// ---------- Customers ----------
let custSearchTimer = null;
async function loadCustomerTable(page = 1) {
  const search = document.getElementById('cust-search').value.trim();
  const accountType = document.getElementById('cust-filter-type').value;
  const segment = document.getElementById('cust-filter-segment').value;
  const params = new URLSearchParams({ page, pageSize: 10, search, accountType, segment });
  const data = await fetch('/api/customers?' + params).then(r => r.json());

  document.querySelector('#customer-table tbody').innerHTML = data.rows.map(c =>
    `<tr><td>${c.CustomerID}</td><td>${c.CustomerName}</td><td>${c.AccountType}</td><td>${c.CustomerSegment}</td></tr>`
  ).join('') || '<tr><td colspan="4">No customers match.</td></tr>';

  renderPagination('customer-pagination', data.total, data.page, data.pageSize, loadCustomerTable);
}
document.getElementById('cust-search').addEventListener('input', () => {
  clearTimeout(custSearchTimer);
  custSearchTimer = setTimeout(() => loadCustomerTable(1), 300);
});
document.getElementById('cust-filter-type').addEventListener('change', () => loadCustomerTable(1));
document.getElementById('cust-filter-segment').addEventListener('change', () => loadCustomerTable(1));

document.getElementById('add-customer').addEventListener('click', async () => {
  const feedback = document.getElementById('customer-feedback');
  const name = document.getElementById('cust-name').value.trim();
  if (!name) { feedback.className = 'feedback err'; feedback.textContent = 'Name is required.'; return; }

  try {
    const res = await fetch('/api/customers', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        customerName: name,
        accountType: document.getElementById('cust-type').value,
        customerSegment: document.getElementById('cust-segment').value
      })
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error);
    feedback.className = 'feedback ok';
    feedback.textContent = `Added as customer #${data.customerId}.`;
    document.getElementById('cust-name').value = '';
    await loadCustomers();
    await loadCustomerTable(1);
  } catch (err) {
    feedback.className = 'feedback err'; feedback.textContent = err.message;
  }
});

// ---------- Debts ----------
let debtSearchTimer = null;
async function loadDebts(page = 1) {
  const search = document.getElementById('debts-search').value.trim();
  const params = new URLSearchParams({ page, pageSize: 5, search });
  const data = await fetch('/api/debts?' + params).then(r => r.json());

  document.getElementById('debts-toolbar').style.display = data.grandTotal > 5 ? 'flex' : 'none';

  document.querySelector('#debts-table tbody').innerHTML = data.rows.map(d => `
    <tr>
      <td>${d.CustomerName}</td>
      <td class="mono">${peso(d.AmountDue)}</td>
      <td>${new Date(d.DateIncurred).toLocaleDateString()}</td>
      <td>${d.DaysOutstanding}</td>
      <td><button class="settle-btn" data-id="${d.DebtID}">Mark paid</button></td>
    </tr>`).join('') || '<tr><td colspan="5">No open debts.</td></tr>';

  renderPagination('debts-pagination', data.grandTotal > 5 ? data.total : 0, data.page, data.pageSize, loadDebts);

  document.querySelectorAll('.settle-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
      const channel = prompt('Settled via Cash or GCash?', 'Cash');
      if (!channel) return;
      const res = await fetch(`/api/debts/${btn.dataset.id}/settle`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ channel })
      });
      const respData = await res.json();
      const feedback = document.getElementById('debts-feedback');
      if (!res.ok) { feedback.className = 'feedback err'; feedback.textContent = respData.error; return; }
      feedback.className = 'feedback ok'; feedback.textContent = 'Debt settled.';
      loadDebts(page);
    });
  });
}
document.getElementById('debts-search').addEventListener('input', () => {
  clearTimeout(debtSearchTimer);
  debtSearchTimer = setTimeout(() => loadDebts(1), 300);
});
document.getElementById('history-search').addEventListener('input', () => {
  clearTimeout(historySearchTimer);
  historySearchTimer = setTimeout(() => loadHistory(1), 300);
});

// ---------- Advance payments ----------
document.getElementById('submit-deposit').addEventListener('click', async () => {
  const feedback = document.getElementById('deposit-feedback');
  const body = {
    customerId: parseInt(document.getElementById('deposit-customer').value, 10),
    amount: parseFloat(document.getElementById('deposit-amount').value),
    channel: document.getElementById('deposit-channel').value
  };
  if (!body.amount || body.amount <= 0) { feedback.className = 'feedback err'; feedback.textContent = 'Enter a valid amount.'; return; }

  try {
    const res = await fetch('/api/deposits', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error);
    feedback.className = 'feedback ok';
    feedback.textContent = `Deposit logged — expires ${new Date(data.ExpiryDate).toLocaleDateString()}.`;
    document.getElementById('deposit-amount').value = '';
  } catch (err) {
    feedback.className = 'feedback err'; feedback.textContent = err.message;
  }
});

document.getElementById('check-balance').addEventListener('click', async () => {
  const id = document.getElementById('balance-customer').value;
  const data = await fetch('/api/balance/' + id).then(r => r.json());
  document.getElementById('balance-display').textContent = peso(data.CurrentBalance);
});

// ---------- History ----------
let historySearchTimer = null;
async function loadHistory(page = 1) {
  const search = document.getElementById('history-search').value.trim();
  const params = new URLSearchParams({ page, pageSize: 10, search });
  const data = await fetch('/api/transactions/recent?' + params).then(r => r.json());

  document.querySelector('#history-table tbody').innerHTML = data.rows.map(t => `
    <tr data-id="${t.TransactionID}">
      <td>${t.TransactionID}</td>
      <td>${new Date(t.TransactionDate).toLocaleString()}</td>
      <td>${t.CustomerName}</td>
      <td class="name-cell">${t.NameOnRecord}</td>
      <td>${t.FundingType}${t.ShippingFlag ? ' + ship' : ''}</td>
      <td class="mono">${peso(t.TotalAmount)}</td>
      <td class="row-actions">
        <button class="icon-btn edit-txn" title="Edit name on record">✎</button>
        <button class="icon-btn danger delete-txn" title="Void transaction">🗑</button>
      </td>
    </tr>`).join('');

  renderPagination('history-pagination', data.total, data.page, data.pageSize, loadHistory);

  document.querySelectorAll('.edit-txn').forEach(btn => {
    btn.addEventListener('click', () => {
      const row = btn.closest('tr');
      const cell = row.querySelector('.name-cell');
      const current = cell.textContent;
      cell.innerHTML = `<input type="text" class="edit-name-input" value="${current}">`;
      const input = cell.querySelector('input');
      input.focus();
      const save = async () => {
        const feedback = document.getElementById('history-feedback');
        try {
          const res = await fetch(`/api/transactions/${row.dataset.id}`, {
            method: 'PUT', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ nameOnRecord: input.value.trim() })
          });
          const respData = await res.json();
          if (!res.ok) throw new Error(respData.error);
          feedback.className = 'feedback ok'; feedback.textContent = 'Updated.';
          loadHistory(page);
        } catch (err) {
          feedback.className = 'feedback err'; feedback.textContent = err.message;
        }
      };
      input.addEventListener('blur', save);
      input.addEventListener('keydown', e => { if (e.key === 'Enter') input.blur(); });
    });
  });

  document.querySelectorAll('.delete-txn').forEach(btn => {
    btn.addEventListener('click', async () => {
      const row = btn.closest('tr');
      if (!confirm(`Void transaction #${row.dataset.id}? This cannot be undone.`)) return;
      const feedback = document.getElementById('history-feedback');
      try {
        const res = await fetch(`/api/transactions/${row.dataset.id}`, { method: 'DELETE' });
        const respData = await res.json();
        if (!res.ok) throw new Error(respData.error);
        feedback.className = 'feedback ok'; feedback.textContent = `Transaction #${row.dataset.id} voided.`;
        loadHistory(page);
        loadPoints(1);
      } catch (err) {
        feedback.className = 'feedback err'; feedback.textContent = err.message;
      }
    });
  });
}

// ---------- Points (derived, read-only) ----------
async function loadPoints(page = 1) {
  const year = document.getElementById('points-year-filter').value;
  const params = new URLSearchParams({ page, pageSize: 10, year });
  const data = await fetch('/api/points?' + params).then(r => r.json());
  document.querySelector('#points-table tbody').innerHTML = data.rows.map(r => `
    <tr>
      <td>${r.CustomerName}</td>
      <td>${r.FiscalYear}</td>
      <td>${r.SlimRoundQtyPurchased}</td>
      <td>${r.PointsFromSlimRound}</td>
      <td class="mono">${peso(r.AmountDeposited)}</td>
      <td>${r.PointsFromAdvancePayment}</td>
      <td><strong>${r.TotalPoints}</strong></td>
    </tr>`).join('');
  renderPagination('points-pagination', data.total, data.page, data.pageSize, loadPoints);
}

document.getElementById('points-year-filter').addEventListener('change', () => loadPoints(1));

// ---------- Init ----------
(async function init() {
  await loadCustomers();
  await loadItems();
  addLine();
  await loadPriceReference();
  const years = await fetch('/api/points/years').then(r => r.json());
  const yearSel = document.getElementById('points-year-filter');
  years.forEach(y => {
    const opt = document.createElement('option');
    opt.value = y; opt.textContent = `FY ${y}-${y + 1}`;
    yearSel.appendChild(opt);
  });
})();
