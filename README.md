# Water Store Register

A lightweight point-of-sale (POS) web application for a drinking water store. The system manages sales, customers, debts, advance-payment balances, transaction history, and a customer rewards program.

This project was developed for Tubig Talino, the water refilling station of Buhay Autismo Inc. (BAI) in Carmona, Cavite. The application replaces the store's traditional handwritten record-keeping system with a web-based point-of-sale and customer management system, allowing staff to efficiently record sales, manage customer accounts, monitor debts and advance payments, and track customer rewards. Tubig Talino is one of BAI's livelihood initiatives, supporting the organization's mission of improving opportunities for individuals with Autism Spectrum Disorder (ASD) and their families.

The application uses SQL Server as the primary source of business logic. Pricing, promotions, debt handling, advance-payment balances, and points calculations are performed through stored procedures and views. The web application simply provides the interface for interacting with those database objects.

---

## Features

- Create new sales
- Automatic pricing based on customer segment
- Customer management
- Debt tracking and settlement
- Advance-payment balance management
- Transaction history
- Customer rewards and points tracking
- Search, filtering, and pagination where applicable

---

## Built With

### Backend

- Node.js
- Express
- mssql

The backend communicates directly with SQL Server stored procedures and views. No ORM is used because the database already contains the application's business logic.

### Frontend

- HTML
- CSS
- Vanilla JavaScript

The frontend intentionally avoids frameworks or build tools. Since this is an internal register application used by rotating staff, the project remains simple to deploy and maintain.

### Database

- Microsoft SQL Server
- SQL Server Management Studio (SSMS)

The application authenticates using a dedicated SQL Login instead of Windows Authentication. This approach is easier to deploy from Node.js and is the standard practice for applications connecting to SQL Server.

---

# Screenshots

| | |
|---|---|
| ![Home](placeholder.png) | ![Customers](placeholder.png) |
| **Figure 1. Home page** | **Figure 2. Customers page** |

| | |
|---|---|
| ![Debts](placeholder.png) | ![Advance Payments](placeholder.png) |
| **Figure 3. Debts page** | **Figure 4. Advance Payments page** |

<p align="center">
<img src="images/history-placeholder.png" width="700">
</p>

<p align="center">
<b>Figure 5. History & Points page</b>
</p>

---

# Requirements

Before running the application, install:

- Node.js (LTS)
- SQL Server (2016 or newer)
- SQL Server Management Studio (SSMS)
- Git (optional, only if cloning the repository)

---

# Installation

## 1. Clone the repository

```bash
git clone https://github.com/malxav/water-store-register.git
cd water-store-register
```

Or download the project as a ZIP from GitHub and extract it.

---

## 2. Set up the database

Run the SQL scripts inside the `sql` folder in the following order.

| Script | Description |
|---------|-------------|
| `01_schema.sql` | Creates the database, tables, starter data, and configuration values. |
| `02_procs.sql` | Creates stored procedures and operational views. |
| `03_points_update.sql` | Creates the customer points view and updates the points configuration. |

Each script drops and recreates its objects, making them safe to run again if necessary.

---

## 3. Create a SQL Login

Run the following inside SSMS:

```sql
USE master;
CREATE LOGIN waterstore_app WITH PASSWORD='ChangeThisPassword123!';

USE WaterStoreDB;

CREATE USER waterstore_app FOR LOGIN waterstore_app;

ALTER ROLE db_datareader ADD MEMBER waterstore_app;
ALTER ROLE db_datawriter ADD MEMBER waterstore_app;

GRANT EXECUTE TO waterstore_app;
```

If SQL Server only allows Windows Authentication, enable Mixed Mode Authentication in:

```
Server Properties
→ Security
→ SQL Server and Windows Authentication mode
```

Restart the SQL Server service afterward.

---

## 4. Install dependencies

```bash
npm install
```

---

## 5. Configure the application

Copy

```
.env.example
```

to

```
.env
```

and update the connection settings.

```text
DB_SERVER=localhost
DB_DATABASE=WaterStoreDB
DB_USER=waterstore_app
DB_PASSWORD=your_password
DB_PORT=1433
PORT=3000
```

The `.env` file is ignored by Git and should never be committed.

---

## 6. Start the application

```bash
npm start
```

Then open

```
http://localhost:3000
```

Alternatively, you can run WaterStoreTools.bat and select option 1.

---

# Application Pages

## New Sale

- Select an existing customer or use Walk-in.
- Add one or more products.
- Prices update automatically according to the customer's pricing segment.
- Choose the payment method.
- Optional delivery charge.
- Submit the completed sale.

## Customers

- Add customers.
- Browse all customers.
- Search by name.
- Filter by customer type and pricing segment.
- Pagination for large customer lists.

## Debts

- View every unpaid debt.
- Search customers with outstanding balances.
- Settle debts with a single click.

## Advance Payments

- Add advance-payment deposits.
- Check customer balances.

## History & Points

- View transaction history.
- Edit the recorded customer name for typo corrections.
- Void incorrect transactions.
- View customer points by fiscal year.

---

# CRUD Operations

### Customers

- Create
- Read

Customer records are intentionally not editable or removable because they represent real customer accounts.

### Debts

- Create
- Read
- Settle

Debt records represent actual financial transactions and are not edited or deleted.

### Advance Payments

- Create
- Read

Deposits are permanent financial records and should not be modified after creation.

### Transactions

Transactions support limited updates.

You may:

- Edit the recorded customer name to fix typing mistakes.
- Void an incorrect transaction.

Other edits such as changing payment type, quantities, or prices are intentionally unavailable because they would require recalculating pricing, promotions, balances, and debts. Those rules are already implemented inside `usp_CreateTransaction`. If a transaction was entered incorrectly, the recommended workflow is to void it and create a new one.

### Points

No CRUD operations are provided.

Customer points are calculated through the `vw_CustomerPoints` view using transactions and deposits. Editing the underlying data automatically updates the points totals.

---

# Project Structure

```text
water-store-register/
│
├── sql/
│   ├── 01_schema.sql
│   ├── 02_procs.sql
│   └── 03_points_update.sql
│
├── public/
│   ├── index.html
│   ├── css/
│   └── js/
│
├── db.js
├── server.js
├── package.json
├── .env.example
└── .gitignore
```

---

# Future Improvements

Several configuration values remain placeholders inside `AppConfig`.

These include:

- Bottled water points divisor
- Advance-payment points conversion values
- Advance-payment expiration policy

Once finalized, these values can be updated without changing the application code.

The current application is intended for a single register using `localhost`. Since the backend communicates through Express and SQL Server, migrating to a shared server for multiple registers would only require updating the database connection settings.