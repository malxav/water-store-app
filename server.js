const express = require('express');
const path = require('path');
const { sql, poolPromise } = require('./db');

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

function paged(req, defaultSize = 10) {
  const page = Math.max(parseInt(req.query.page, 10) || 1, 1);
  const pageSize = Math.max(parseInt(req.query.pageSize, 10) || defaultSize, 1);
  return { page, pageSize, offset: (page - 1) * pageSize };
}

// ---------- Customers ----------
// Supports: ?page=&pageSize=&search=&accountType=&segment=
app.get('/api/customers', async (req, res) => {
  const { page, pageSize, offset } = paged(req);
  const { search = '', accountType = '', segment = '' } = req.query;
  try {
    const pool = await poolPromise;
    const request = pool.request();
    request.multiple = true;

    const conditions = [];
    if (search) { conditions.push('CustomerName LIKE @Search'); request.input('Search', sql.VarChar, `%${search}%`); }
    if (accountType) { conditions.push('AccountType = @AccountType'); request.input('AccountType', sql.VarChar, accountType); }
    if (segment) { conditions.push('CustomerSegment = @Segment'); request.input('Segment', sql.VarChar, segment); }
    const where = conditions.length ? 'WHERE ' + conditions.join(' AND ') : '';

    request.input('Offset', sql.Int, offset);
    request.input('PageSize', sql.Int, pageSize);

    const result = await request.query(`
      SELECT CustomerID, CustomerName, AccountType, CustomerSegment, DateJoined
      FROM dbo.Customer
      ${where}
      ORDER BY CustomerID
      OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;

      SELECT COUNT(*) AS Total FROM dbo.Customer ${where};
    `);

    res.json({ rows: result.recordsets[0], total: result.recordsets[1][0].Total, page, pageSize });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Unfiltered, unpaginated list - used to populate dropdowns elsewhere (sale form, deposits, etc.)
app.get('/api/customers/all', async (req, res) => {
  try {
    const pool = await poolPromise;
    const result = await pool.request().query(
      'SELECT CustomerID, CustomerName, AccountType, CustomerSegment FROM dbo.Customer ORDER BY CustomerID'
    );
    res.json(result.recordset);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/customers', async (req, res) => {
  const { customerName, accountType, customerSegment } = req.body;
  if (!customerName) return res.status(400).json({ error: 'customerName is required.' });
  try {
    const pool = await poolPromise;
    const result = await pool.request()
      .input('CustomerName', sql.VarChar(100), customerName)
      .input('AccountType', sql.VarChar(20), accountType || 'Individual')
      .input('CustomerSegment', sql.VarChar(20), customerSegment || 'Regular')
      .query(`INSERT INTO dbo.Customer (CustomerName, AccountType, CustomerSegment)
              OUTPUT INSERTED.CustomerID
              VALUES (@CustomerName, @AccountType, @CustomerSegment)`);
    res.json({ customerId: result.recordset[0].CustomerID });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------- Items & live pricing ----------

app.get('/api/items', async (req, res) => {
  try {
    const pool = await poolPromise;
    const result = await pool.request().query(
      'SELECT ItemID, ItemName, IsFreeVariant, LinkedItemID FROM dbo.Item ORDER BY ItemID'
    );
    res.json(result.recordset);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/pricelist', async (req, res) => {
  const segment = req.query.segment || 'Regular';
  try {
    const pool = await poolPromise;
    const result = await pool.request()
      .input('Segment', sql.VarChar(20), segment)
      .query(`SELECT p.ItemID, i.ItemName, i.IsFreeVariant, p.UnitPrice
              FROM dbo.PriceList p
              JOIN dbo.Item i ON i.ItemID = p.ItemID
              WHERE p.CustomerSegment = @Segment
                AND p.EffectiveDate = (
                  SELECT MAX(EffectiveDate) FROM dbo.PriceList p2
                  WHERE p2.ItemID = p.ItemID AND p2.CustomerSegment = @Segment
                )
              ORDER BY p.ItemID`);
    res.json(result.recordset);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ---------- Transactions ----------

app.post('/api/transactions', async (req, res) => {
  const { customerId, nameOnRecord, fundingType, shippingFlag, lines } = req.body;
  if (!nameOnRecord || !fundingType || !Array.isArray(lines) || lines.length === 0) {
    return res.status(400).json({ error: 'nameOnRecord, fundingType, and at least one line item are required.' });
  }
  try {
    const pool = await poolPromise;
    const table = new sql.Table('dbo.TransactionLineType');
    table.columns.add('ItemID', sql.Int);
    table.columns.add('Quantity', sql.Int);
    lines.forEach(l => table.rows.add(l.itemId, l.quantity));

    const result = await pool.request()
      .input('CustomerID', sql.Int, customerId ?? 0)
      .input('NameOnRecord', sql.VarChar(100), nameOnRecord)
      .input('FundingType', sql.VarChar(20), fundingType)
      .input('ShippingFlag', sql.Bit, shippingFlag ? 1 : 0)
      .input('Lines', table)
      .output('TransactionID', sql.Int)
      .execute('dbo.usp_CreateTransaction');

    const txnId = result.output.TransactionID;
    const txn = await pool.request()
      .input('TransactionID', sql.Int, txnId)
      .query('SELECT * FROM dbo.SalesTransaction WHERE TransactionID = @TransactionID');

    res.json(txn.recordset[0]);
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// Paginated recent transactions: ?page=&pageSize=
app.get('/api/transactions/recent', async (req, res) => {
  const { page, pageSize, offset } = paged(req);
  const { search = '' } = req.query;
  try {
    const pool = await poolPromise;
    const request = pool.request();
    request.multiple = true;
    request.input('Offset', sql.Int, offset);
    request.input('PageSize', sql.Int, pageSize);

    let where = '';
    if (search) {
      where = 'WHERE CAST(t.TransactionID AS VARCHAR) = @SearchExact OR t.NameOnRecord LIKE @SearchLike OR c.CustomerName LIKE @SearchLike';
      request.input('SearchExact', sql.VarChar, search);
      request.input('SearchLike', sql.VarChar, `%${search}%`);
    }

    const result = await request.query(`
      SELECT t.TransactionID, t.TransactionDate, c.CustomerName, t.NameOnRecord,
             t.FundingType, t.ShippingFlag, t.TotalAmount
      FROM dbo.SalesTransaction t
      JOIN dbo.Customer c ON c.CustomerID = t.CustomerID
      ${where}
      ORDER BY t.TransactionID DESC
      OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;

      SELECT COUNT(*) AS Total FROM dbo.SalesTransaction t JOIN dbo.Customer c ON c.CustomerID = t.CustomerID ${where};
    `);
    res.json({ rows: result.recordsets[0], total: result.recordsets[1][0].Total, page, pageSize });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Edit: NameOnRecord only. Line items and FundingType are intentionally
// not editable here. Changing quantities would require re-running the
// pricing/promo logic, and changing FundingType has knock-on effects
// (creating/removing a Debt row, balance validation). For those cases,
// void the transaction and re-enter it through New Sale so the stored
// procedure stays the single source of truth for that logic.
app.put('/api/transactions/:id', async (req, res) => {
  const { nameOnRecord } = req.body;
  if (!nameOnRecord) return res.status(400).json({ error: 'nameOnRecord is required.' });
  try {
    const pool = await poolPromise;
    const result = await pool.request()
      .input('TransactionID', sql.Int, req.params.id)
      .input('NameOnRecord', sql.VarChar(100), nameOnRecord)
      .query('UPDATE dbo.SalesTransaction SET NameOnRecord = @NameOnRecord WHERE TransactionID = @TransactionID');
    if (result.rowsAffected[0] === 0) return res.status(404).json({ error: 'Transaction not found.' });
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Void (delete) a transaction and everything tied to it.
app.delete('/api/transactions/:id', async (req, res) => {
  const pool = await poolPromise;
  const tx = new sql.Transaction(pool);
  try {
    await tx.begin();
    const request = new sql.Request(tx);
    request.input('TransactionID', sql.Int, req.params.id);

    await request.query('DELETE FROM dbo.Debt WHERE TransactionID = @TransactionID');
    await request.query('DELETE FROM dbo.TransactionDetail WHERE TransactionID = @TransactionID');
    const result = await request.query('DELETE FROM dbo.SalesTransaction WHERE TransactionID = @TransactionID');

    if (result.rowsAffected[0] === 0) {
      await tx.rollback();
      return res.status(404).json({ error: 'Transaction not found.' });
    }
    await tx.commit();
    res.json({ ok: true });
  } catch (err) {
    await tx.rollback();
    res.status(500).json({ error: err.message });
  }
});

// ---------- Debts ----------
// Supports: ?page=&pageSize=&search=  (search matches customer name)
app.get('/api/debts', async (req, res) => {
  const { page, pageSize, offset } = paged(req, 5);
  const { search = '' } = req.query;
  try {
    const pool = await poolPromise;
    const request = pool.request();
    request.multiple = true;
    request.input('Offset', sql.Int, offset);
    request.input('PageSize', sql.Int, pageSize);

    const where = search ? 'WHERE CustomerName LIKE @Search' : '';
    if (search) request.input('Search', sql.VarChar, `%${search}%`);

    const result = await request.query(`
      SELECT * FROM dbo.vw_OpenDebts
      ${where}
      ORDER BY DateIncurred
      OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;

      SELECT COUNT(*) AS Total FROM dbo.vw_OpenDebts ${where};

      SELECT COUNT(*) AS GrandTotal FROM dbo.Debt WHERE Status = 'Unpaid';
    `);

    res.json({
      rows: result.recordsets[0],
      total: result.recordsets[1][0].Total,
      grandTotal: result.recordsets[2][0].GrandTotal,
      page, pageSize
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/debts/:id/settle', async (req, res) => {
  const { channel } = req.body;
  try {
    const pool = await poolPromise;
    await pool.request()
      .input('DebtID', sql.Int, req.params.id)
      .input('Channel', sql.VarChar(20), channel)
      .execute('dbo.usp_SettleDebt');
    res.json({ ok: true });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// ---------- Advance payments ----------

app.get('/api/balance/:customerId', async (req, res) => {
  try {
    const pool = await poolPromise;
    const result = await pool.request()
      .input('CustomerID', sql.Int, req.params.customerId)
      .query('SELECT * FROM dbo.vw_CustomerBalance WHERE CustomerID = @CustomerID');
    res.json(result.recordset[0] || { CurrentBalance: 0 });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/deposits', async (req, res) => {
  const { customerId, amount, channel } = req.body;
  try {
    const pool = await poolPromise;
    const result = await pool.request()
      .input('CustomerID', sql.Int, customerId)
      .input('Amount', sql.Decimal(10, 2), amount)
      .input('Channel', sql.VarChar(20), channel)
      .execute('dbo.usp_AddAdvancePaymentDeposit');
    res.json(result.recordset[0]);
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// ---------- Points (read-only - derived from transactions/deposits, not directly editable) ----------
// Supports: ?page=&pageSize=
app.get('/api/points', async (req, res) => {
  const { page, pageSize, offset } = paged(req);
  const { year = '' } = req.query;
  try {
    const pool = await poolPromise;
    const request = pool.request();
    request.multiple = true;
    request.input('Offset', sql.Int, offset);
    request.input('PageSize', sql.Int, pageSize);

    // Excludes CustomerID 0 (walk-in) and any Organization account (PDAO e.g.)
    const conditions = ["c.CustomerID <> 0", "c.AccountType <> 'Organization'"];
    if (year) { conditions.push('vp.FiscalYear = @Year'); request.input('Year', sql.Int, parseInt(year, 10)); }
    const where = 'WHERE ' + conditions.join(' AND ');

    const result = await request.query(`
      SELECT vp.CustomerID, c.CustomerName, vp.FiscalYear, vp.SlimRoundQtyPurchased,
             vp.PointsFromSlimRound, vp.AmountDeposited, vp.PointsFromAdvancePayment, vp.TotalPoints
      FROM dbo.vw_CustomerPoints vp
      JOIN dbo.Customer c ON c.CustomerID = vp.CustomerID
      ${where}
      ORDER BY vp.FiscalYear DESC, c.CustomerName
      OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;

      SELECT COUNT(*) AS Total FROM dbo.vw_CustomerPoints vp JOIN dbo.Customer c ON c.CustomerID = vp.CustomerID ${where};
    `);
    res.json({ rows: result.recordsets[0], total: result.recordsets[1][0].Total, page, pageSize });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/points/years', async (req, res) => {
  try {
    const pool = await poolPromise;
    const result = await pool.request().query(`
      SELECT DISTINCT vp.FiscalYear
      FROM dbo.vw_CustomerPoints vp
      JOIN dbo.Customer c ON c.CustomerID = vp.CustomerID
      WHERE c.CustomerID <> 0 AND c.AccountType <> 'Organization'
      ORDER BY vp.FiscalYear DESC
    `);
    res.json(result.recordset.map(r => r.FiscalYear));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`Water store app running at http://localhost:${PORT}`));
