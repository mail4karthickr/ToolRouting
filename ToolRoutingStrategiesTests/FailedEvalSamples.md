# Failed Eval Samples

Evaluation: `HybridAnswerEvaluation`  
Result ID: `6B2EF8FC-4AF5-4244-971E-B85BEC40DF52`  
Run: `Test-ToolRoutingStrategies-2026.08.12_08-30-34-+0530.xcresult`  
Strategy: Hybrid cascade end to end (retrieval → selection → agent)  
Model: all-MiniLM-L6-v2 (MLX) + SystemLanguageModel  
Judge: Claude Opus 5 (ClaudeForFoundationModels)

**20 of 60 samples failed** — 17 on judge scores (Fabrication = 0, or Faithfulness / Completeness / Naturalness <= 2), 14 on tool routing, 11 on both.

---

## Sample 3 — faithfulness=2, completeness=1

**Question**

> How late is the nearest branch open?

**Answer (actual)**

> The Airport Branch closes at 8 pm on weekdays.

**Expected answer**

> The closest is Main St Branch, and it's open until 5 pm on weekdays.

Tools expected: `['get_location', 'find_branch', 'branch_hours']`  
Tools executed: `['get_location', 'find_branch', 'branch_hours']`  
Scores: Fabrication 1 · Faithfulness 2 · Completeness 1 · Naturalness 4

---

## Sample 7 — routing

**Question**

> Find the nearest ATM and tell me my daily withdrawal limit

**Answer (actual)**

> The nearest ATM is Market Square ATM, which is 0.1 miles away and open 24 hours. Your daily ATM withdrawal limit is $1,000.

**Expected answer**

> The Market Square ATM is 0.1 mi away and open 24 h, and your daily ATM withdrawal limit is $1,000.

Tools expected: `['get_location', 'find_atm', 'card_limits']`  
Tools executed: `['find_atm', 'card_limits']`  
Scores: Fabrication 1 · Faithfulness 4 · Completeness 4 · Naturalness 4

---

## Sample 11 — fabrication, faithfulness=1, routing

**Question**

> Find a branch near me, its hours, and the nearest ATM

**Answer (actual)**

> The Main St Branch is 0.9 miles away, open Monday through Friday from 9 am to 5 pm, Saturday from 9 am to 1 pm, and closed Sunday. The nearest ATM is the Market Square ATM, which is 0.1 miles away and open 24 hours.

**Expected answer**

> Main St Branch is 0.4 mi away and open until 5 pm, and the Market Square ATM is 0.1 mi away.

Tools expected: `['get_location', 'find_branch', 'find_atm']`  
Tools executed: `['get_location', 'find_branch', 'branch_hours', 'find_atm', 'compute']`  
Scores: Fabrication 0 · Faithfulness 1 · Completeness 4 · Naturalness 4

---

## Sample 14 — routing

**Question**

> Find a branch downtown and tell me its hours

**Answer (actual)**

> The Main St Branch is open Monday through Friday from 9 am to 5 pm, Saturday from 9 am to 1 pm, and is closed Sunday.

**Expected answer**

> Main St Branch is 0.4 mi away and is open Mon–Fri 9 am–5 pm, Sat 9 am–1 pm.

Tools expected: `['find_branch', 'branch_hours']`  
Tools executed: `['get_location', 'find_branch', 'branch_hours']`  
Scores: Fabrication 1 · Faithfulness 4 · Completeness 4 · Naturalness 4

---

## Sample 19 — fabrication

**Question**

> Tell me my savings balance, the interest it earned, and that balance in euros

**Answer (actual)**

> Your savings balance is $8,120.55, which is 7,470.91 EUR, and it earned $27.

**Expected answer**

> Savings is $8,120.55, it earned $27.14 in interest last month, and that comes to 7,470.91 EUR.

Tools expected: `['account_balance', 'interest_earned', 'convert_currency']`  
Tools executed: `['account_balance', 'interest_earned', 'convert_currency']`  
Scores: Fabrication 0 · Faithfulness 3 · Completeness 3 · Naturalness 4

---

## Sample 21 — fabrication, faithfulness=1, completeness=1, routing

**Question**

> pts balance

**Answer (actual)**

> Your total balance across all accounts is $11,665.54.

**Expected answer**

> You have 18,420 reward points.

Tools expected: `['reward_points']`  
Tools executed: `['account_balance', 'compute']`  
Scores: Fabrication 0 · Faithfulness 1 · Completeness 1 · Naturalness 4

---

## Sample 23 — fabrication, faithfulness=1

**Question**

> What's my balance, my credit score, and my reward points?

**Answer (actual)**

> Your balance is $10,065.58, your credit score is 742, and your reward points are 18,420.

**Expected answer**

> Checking is $2,340.12 and savings is $8,120.55, your credit score is 742, and you have 18,420 reward points.

Tools expected: `['account_balance', 'credit_score', 'reward_points']`  
Tools executed: `['account_balance', 'credit_score', 'reward_points']`  
Scores: Fabrication 0 · Faithfulness 1 · Completeness 3 · Naturalness 4

---

## Sample 26 — faithfulness=2, routing

**Question**

> Show my balance and this week's transactions

**Answer (actual)**

> Your current balance is $10,000. Here are this week's transactions:
>
> - 12 Aug · Starbucks · Checking · -$6.45
> - 11 Aug · Amazon · Credit Card · -$82.19
> - 11 Aug · Shell Gas Station · Credit Card · -$48.30
> - 10 Aug · Whole Foods Market · Checking · -$114.62
> - 9 Aug · Payroll — ACME Corp · Checking · $2,450.00
> - 8 Aug · Netflix · Credit Card · -$15.49
> - 7 Aug · Monthly Service Fee · Checking · -$12.00
> - 6 Aug · Uber · Credit Card · -$23.75
>
> You spent $82.19 at Amazon this week.

**Expected answer**

> Checking is $2,340.12 and savings is $8,120.55, with recent activity including $6.45 at Starbucks and $82.19 at Amazon.

Tools expected: `['account_balance', 'list_transactions']`  
Tools executed: `['account_balance', 'list_transactions', 'compute']`  
Scores: Fabrication 1 · Faithfulness 2 · Completeness 3 · Naturalness 3

---

## Sample 27 — fabrication, naturalness=2

**Question**

> Show my recent transactions, pending payments, and scheduled payments

**Answer (actual)**

> Here are your recent transactions, pending payments, and scheduled payments:
>
> Recent transactions:
> - 12 Aug · Starbucks · Checking · -$6.45
> - 11 Aug · Amazon · Credit Card · -$82.19
> - 11 Aug · Shell Gas Station · Credit Card · -$48.30
> - 10 Aug · Whole Foods Market · Checking · -$114.62
> - 9 Aug · Payroll — ACME Corp · Checking · $2,450.00
> - 8 Aug · Netflix · Credit Card · -$15.49
> - 7 Aug · Monthly Service Fee · Checking · -$12.00
> - 6 Aug · Uber · Credit Card · -$23.75
> - 4 Aug · Transfer to Savings · Checking · -$500.00
> - 4 Aug · Transfer from Checking · Savings · $500.00
> - 2 Aug · Apple.com · Credit Card · -$9.99
> - 31 Jul · PG&E — Electricity · Checking · -$96.40
>
> Pending payments:
> - Netflix — $15.49 (processing)
> - PG&E Electricity — $96.40 (scheduled for the 1st)
>
> Scheduled payments:
> - Rent transfer — $1,850 (scheduled for the 1st)
> - Credit card autopay — statement balance (scheduled for the 5th)
> - Gym membership — $45 (scheduled for the 12th)

**Expected answer**

> Recent activity includes $6.45 at Starbucks and $82.19 at Amazon, Netflix for $15.49 is pending, and rent of $1,850 is scheduled for the 1st.

Tools expected: `['list_transactions', 'pending_payments', 'scheduled_payments']`  
Tools executed: `['list_transactions', 'pending_payments', 'scheduled_payments']`  
Scores: Fabrication 0 · Faithfulness 4 · Completeness 4 · Naturalness 2

---

## Sample 29 — faithfulness=2, naturalness=2

**Question**

> Show my recent transactions

**Answer (actual)**

> Here are your recent transactions:
>
> - 12 Aug · Starbucks · Checking · -$6.45
> - 11 Aug · Amazon · Credit Card · -$82.19
> - 11 Aug · Shell Gas Station · Credit Card · -$48.30
> - 10 Aug · Whole Foods Market · Checking · -$114.62
> - 9 Aug · Payroll — ACME Corp · Checking · $2,450.00
> - 8 Aug · Netflix · Credit Card · -$15.49
> - 7 Aug · Monthly Service Fee · Checking · -$12.00
> - 6 Aug · Uber · Credit Card · -$23.75

**Expected answer**

> Recent activity includes $6.45 at Starbucks, $82.19 at Amazon, and $114.62 at Whole Foods Market.

Tools expected: `['list_transactions']`  
Tools executed: `['list_transactions']`  
Scores: Fabrication 1 · Faithfulness 2 · Completeness 4 · Naturalness 2

---

## Sample 31 — completeness=1, routing

**Question**

> Give me my account number, routing number, and debit card number

**Answer (actual)**

> (empty — no answer produced)

**Expected answer**

> Account number 4471 9082 3341, routing number 011000000, and debit card 4532 7712 0034 9921.

Tools expected: `['account_number', 'routing_number', 'card_number']`  
Tools executed: `['none']`  
Scores: Fabrication 1 · Faithfulness 4 · Completeness 1 · Naturalness 4

---

## Sample 33 — fabrication, faithfulness=1, completeness=1, routing

**Question**

> Get my June statement

**Answer (actual)**

> Your June spending totals $779.87 across all accounts.

**Expected answer**

> Your June statement for the checking account is ready under Documents.

Tools expected: `['bank_statement']`  
Tools executed: `['bank_statement', 'bank_statement', 'bank_statement', 'compute', 'compute', 'compute', 'compute', 'compute', 'compute']`  
Scores: Fabrication 0 · Faithfulness 1 · Completeness 1 · Naturalness 4

---

## Sample 35 — fabrication, faithfulness=1

**Question**

> What did I spend at Amazon and Starbucks, and what's my card limit?

**Answer (actual)**

> You spent $82.19 at Amazon and $6.45 at Starbucks. Your daily ATM withdrawal limit is $1,000, and your daily spending limit is $3,000.

**Expected answer**

> You spent $82.19 at Amazon and $6.45 at Starbucks, and your credit limit is $10,000.

Tools expected: `['search_transactions', 'search_transactions', 'card_limits']`  
Tools executed: `['search_transactions', 'search_transactions', 'card_limits']`  
Scores: Fabrication 0 · Faithfulness 1 · Completeness 3 · Naturalness 4

---

## Sample 39 — fabrication, routing

**Question**

> What fees did I pay, what interest did I earn, and what's my savings balance?

**Answer (actual)**

> Your total fees paid are $74.00, you earned $27.14 in interest, and your savings balance is $8,120.55.

**Expected answer**

> You paid a $12.00 monthly service fee, earned $27.14 in interest, and savings is $8,120.55.

Tools expected: `['fees_and_charges', 'interest_earned', 'account_balance']`  
Tools executed: `['fees_and_charges', 'interest_earned', 'account_balance', 'compute', 'compute']`  
Scores: Fabrication 0 · Faithfulness 3 · Completeness 4 · Naturalness 4

---

## Sample 47 — fabrication, faithfulness=1, routing

**Question**

> What's the status of my Amazon dispute, how much was the charge, and what's my credit card balance?

**Answer (actual)**

> The Amazon dispute is under review, with a provisional credit issued on Jul 21. The charge at Amazon was $82.19, and your credit card balance is $9,917.81.

**Expected answer**

> The Amazon dispute is under review with provisional credit issued on Jul 21, the charge was $82.19, and your credit card balance is $1,204.87.

Tools expected: `['get_dispute_status', 'search_transactions', 'account_balance']`  
Tools executed: `['get_dispute_status', 'search_transactions', 'card_limits', 'compute', 'compute']`  
Scores: Fabrication 0 · Faithfulness 1 · Completeness 4 · Naturalness 4

---

## Sample 49 — routing

**Question**

> Any ATMs in Chicago?

**Answer (actual)**

> Here are the ATMs near Chicago: Market Square ATM — 0.1 mi, 24 h, Main St Branch ATM — 0.4 mi, 24 h, QuickCash Mart — 0.6 mi, until 11 pm.

**Expected answer**

> The closest is the Market Square ATM at 0.1 mi, open 24 h.

Tools expected: `['find_atm']`  
Tools executed: `['get_location', 'find_atm']`  
Scores: Fabrication 1 · Faithfulness 4 · Completeness 4 · Naturalness 3

---

## Sample 50 — fabrication, routing

**Question**

> Do I have enough in checking to cover the rent payment?

**Answer (actual)**

> Yes, your checking account has $490.12 left after the rent payment.

**Expected answer**

> Checking is $2,340.12 and the rent transfer is $1,850, so yes.

Tools expected: `['account_balance', 'scheduled_payments']`  
Tools executed: `['account_balance', 'scheduled_payments', 'compute']`  
Scores: Fabrication 0 · Faithfulness 4 · Completeness 4 · Naturalness 4

---

## Sample 51 — faithfulness=2, completeness=2, routing

**Question**

> Show my Netflix charges, my pending payments, and my scheduled payments

**Answer (actual)**

> Here are your Netflix charges: $15.49.
>
> Your pending payments include a rent transfer of $1,850 scheduled for the 1st, a credit card autopay for the statement balance scheduled for the 5th, and a gym membership fee of $45 scheduled for the 12th.
>
> Your scheduled payments include the same rent transfer of $1,850 for the 1st, the credit card autopay for the statement balance for the 5th, and the gym membership fee of $45 for the 12th.

**Expected answer**

> Netflix charged $15.49, that payment is still processing, and rent of $1,850 is scheduled for the 1st.

Tools expected: `['search_transactions', 'pending_payments', 'scheduled_payments']`  
Tools executed: `['search_transactions', 'scheduled_payments', 'scheduled_payments', 'scheduled_payments', 'search_transactions']`  
Scores: Fabrication 1 · Faithfulness 2 · Completeness 2 · Naturalness 3

---

## Sample 58 — completeness=2, routing

**Question**

> List my scheduled and pending payments

**Answer (actual)**

> Your scheduled payments include a $1,850 rent transfer for the 1st, a credit card autopay for the 5th, and a $45 gym membership fee for the 12th.

**Expected answer**

> Scheduled: rent $1,850 on the 1st and gym $45 on the 12th. Pending: Netflix $15.49 and PG&E Electricity $96.40.

Tools expected: `['scheduled_payments', 'pending_payments']`  
Tools executed: `['scheduled_payments']`  
Scores: Fabrication 1 · Faithfulness 4 · Completeness 2 · Naturalness 4

---

## Sample 59 — fabrication, routing

**Question**

> What ATMs are near Chicago, what's my withdrawal limit, and my checking balance?

**Answer (actual)**

> Here are the nearby ATMs: Market Square ATM — 0.1 mi, 24 h, Main St Branch ATM — 0.4 mi, 24 h, QuickCash Mart — 0.6 mi, until 11 pm. Your total withdrawal limit is $4,000.00, and your checking balance is $490.12.

**Expected answer**

> The Market Square ATM is 0.1 mi away, your daily ATM withdrawal limit is $1,000, and checking is $2,340.12.

Tools expected: `['find_atm', 'card_limits', 'account_balance']`  
Tools executed: `['get_location', 'find_atm', 'card_limits', 'card_limits', 'compute', 'compute', 'compute', 'compute', 'compute', 'compute', 'compute']`  
Scores: Fabrication 0 · Faithfulness 3 · Completeness 4 · Naturalness 3

---
