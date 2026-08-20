import SwiftUI

enum ToolCatalog {
    static let all: [ToolDefinition] = [
        ToolDefinition(
            displayName: "list_transactions",
            category: .transactions,
            description: "List the user's transactions from the recent past.",
            notFor: "merchant-specific searches (use search_transactions), payments that haven't cleared yet (use pending_payments), or a full statement document (use bank_statement)",
            argumentHint: "how many past days of transactions to show, as a digit, e.g. '7'; use '7' if the user doesn't specify",
            exampleQueries: [
                "Show my transactions from the last week", "What did I spend in the past 3 days?", "List this month's transactions",
                "this weeks txns", "recent txns", "txns"
            ],
            icon: "list.bullet.rectangle",
            color: .blue
        ),
        ToolDefinition(
            displayName: "search_transactions",
            category: .transactions,
            description: "Search the user's past transactions for a specific merchant — including how much they spent at a store or service.",
            notFor: "a general recent listing without a merchant (use list_transactions)",
            argumentHint: "the merchant name, e.g. 'Starbucks'",
            exampleQueries: [
                "What did I spend at Starbucks?", "Show my Amazon purchases", "Any charges from Netflix?",
                "spent at starbucks", "starbucks charges", "amazon spend",
                "how much did i spend at", "what did i spend at a shop", "spending at a merchant",
                "charges from a store", "how much have i spent there", "purchases from a company"
            ],
            icon: "magnifyingglass",
            color: .gray
        ),
        ToolDefinition(
            displayName: "routing_number",
            category: .accounts,
            description: "Show the user's bank routing number — the nine-digit number a transfer or direct deposit needs. The same number for every account the user holds.",
            notFor: "the account number itself (use account_number) or card numbers (use card_number)",
            // A routing number identifies the BANK, not one of the
            // customer's accounts, and `RoutingNumberTool` takes
            // `NoArguments`. This read "which account: checking or
            // savings" until 2026-08-19 — a parameter the tool does not
            // have, on a question that never names an account.
            argumentHint: "no parameters",
            exampleQueries: [
                "What's my routing number?", "I need the routing number for a wire transfer",
                "Routing number for my checking account", "Routing number for my savings account",
                "routing no", "whats my routing no"
            ],
            icon: "number.circle",
            color: .teal
        ),
        ToolDefinition(
            displayName: "account_number",
            category: .accounts,
            description: "Show the user's account number.",
            notFor: "the routing number (use routing_number) or card numbers (use card_number)",
            // NumberRequest.account takes an AccountType, which is four
            // cases, not two — this named only the pair the mock happens
            // to distinguish and left the router thinking `credit card`
            // and `all` were not valid answers here.
            argumentHint: "which account: checking, savings, credit card, or all",
            exampleQueries: [
                "What's my account number?", "Show my savings account number", "I need my checking account number for direct deposit",
                "acct number", "my acc number"
            ],
            icon: "123.rectangle",
            color: .indigo
        ),
        ToolDefinition(
            displayName: "card_number",
            category: .cards,
            description: "Show the number of the user's debit or credit card.",
            notFor: "blocking, freezing, or replacing a card (actions)",
            argumentHint: "which card: debit, credit, or all when the question names none",
            exampleQueries: [
                "What's my debit card number?", "Show my credit card number", "I need my card number",
                "card no", "debit card no"
            ],
            icon: "creditcard",
            color: .purple
        ),
        ToolDefinition(
            displayName: "bank_statement",
            category: .accounts,
            description: "Show the user's bank statement for a given month or period.",
            notFor: "listing individual transactions inline (use list_transactions)",
            argumentHint: "the period, plus which account: checking, savings, credit card, or all when the question names none",
            exampleQueries: [
                "Get my bank statement for June", "Show last month's statement", "Download my checking account statement",
                "june stmt", "last months statement"
            ],
            icon: "doc.text",
            color: .brown
        ),
        ToolDefinition(
            displayName: "credit_score",
            category: .creditAndRewards,
            description: "Show the user's current credit score.",
            // "advice on improving or disputing the score" is one exclusion;
            // the other is unwritten because no tool anywhere covers it: this
            // app tracks no score HISTORY, so "has it changed?" is not a
            // phrasing of "what is it now" — it asks for a comparison this
            // tool cannot make. "Has my credit score changed?" sat in
            // exampleQueries until 2026-08-19 on the assumption that it did,
            // which routed the query here and produced an answer that
            // stated the current score while silently never addressing
            // "changed" — exactly the half-answer RouterPrompt.system's
            // completeness rule calls worse than escalating.
            notFor: "advice on improving or disputing the score, or whether the score has changed (no tool tracks a previous score to compare against)",
            argumentHint: "no parameters",
            exampleQueries: [
                "What's my credit score?", "Show my current credit score", "my fico",
                "fico score", "credit score"
            ],
            icon: "gauge",
            color: .mint
        ),
        ToolDefinition(
            displayName: "get_location",
            category: .locations,
            description: "Get the user's current location, as a place name plus latitude and longitude. Call this FIRST for anything about a nearby branch or ATM. It is the ONLY source of coordinates, so neither find_nearest_branch nor find_nearest_atm can run without it.",
            notFor: "requests that name a place, city, or zip code — no tool takes a place name, so those are `none`",
            argumentHint: "no parameters",
            exampleQueries: [
                "(step 1 of) Find an ATM near me", "(step 1 of) Where's the closest branch?",
                "(step 1 of) nearest atm", "(step 1 of) atm near me"
            ],
            icon: "location.circle",
            color: .pink
        ),
        ToolDefinition(
            displayName: "find_nearest_branch",
            category: .locations,
            // Same two-example split as find_nearest_atm below: the first
            // two are what the selection prompt shows, so the model READS
            // the dependency, and the rest feed the embedding index so
            // retrieval still matches the plain phrasings.
            description: "Find the bank branches closest to a pair of coordinates, each with its branch ID. Takes latitude and longitude from get_location, so get_location has to run first. Its IDs are what branch_hours needs.",
            notFor: "branches at a named city, zip code, or address — this tool takes coordinates and nothing else, so such a request is `none`; also not ATMs (use find_nearest_atm) or booking an appointment (action)",
            argumentHint: "latitude and longitude, both numbers, as returned by get_location",
            exampleQueries: [
                "(step 2 of, after get_location) Find a branch near me",
                "(step 2 of, after get_location) nearest branch",
                "nearest branch", "branch near me", "Where's the closest branch?"
            ],
            icon: "mappin.and.ellipse",
            color: .red
        ),
        ToolDefinition(
            displayName: "find_nearest_atm",
            category: .locations,
            // The first two examples are the two the selection prompt
            // shows (LLMRouter.entry caps at two); the rest exist for the
            // embedding index, which scores every example. So the model
            // READS the dependency and retrieval still matches the plain
            // phrasings. The old entry led with "Find the nearest ATM" as
            // a query this tool served alone, which is exactly what the
            // model believed on eval sample 7.
            description: "Find the ATMs closest to a pair of coordinates. Takes latitude and longitude from get_location, so get_location has to run first.",
            notFor: "ATMs at a named city, zip code, or address — this tool takes coordinates and nothing else, so such a request is `none`; also not branches with tellers (use find_nearest_branch) or changing withdrawal limits (action)",
            argumentHint: "latitude and longitude, both numbers, as returned by get_location",
            exampleQueries: [
                "(step 2 of, after get_location) Find the nearest ATM",
                "(step 2 of, after get_location) atm near me",
                "nearest atm", "closest atm", "atm near me", "Find the nearest ATM"
            ],
            icon: "dollarsign.square",
            color: .yellow
        ),
        ToolDefinition(
            displayName: "fees_and_charges",
            category: .money,
            description: "Show the fees and charges on the user's account, such as the monthly service fee.",
            notFor: "waiving or disputing a fee (actions)",
            // FeesRequest takes an AccountType only. There is no per-fee
            // selector — MockBankAPIClient.feesAndCharges returns the
            // same fixed list of every fee regardless of what it is
            // asked for, so "e.g. 'monthly service fee'" named a filter
            // this tool cannot apply.
            argumentHint: "which account: checking, savings, credit card, or all",
            exampleQueries: [
                "What's my monthly service fee?", "What charges are on my account?",
                "What fees are on my checking account?", "Why am I being charged a service fee?",
                "any fees", "fees on my acct"
            ],
            icon: "dollarsign.circle",
            color: .orange
        ),
        ToolDefinition(
            displayName: "account_balance",
            category: .accounts,
            description: "Show the current balance of the user's accounts (checking, savings, credit card).",
            notFor: "a reward points balance (use reward_points), past transactions (use list_transactions), or payments still processing (use pending_payments)",
            argumentHint: "which account: checking, savings, credit card, or all",
            // One example per ACCOUNT TYPE this tool accepts, not one per
            // phrasing. The description names all three types, but that is
            // a single vector blended across them — ToolIndex scores each
            // example separately and takes the best match, so a type with
            // no example of its own has to win on the blended one. Credit
            // card and checking had none, and "what's my credit card
            // balance?" lost the slot to card_limits, whose first example
            // is "What's my credit limit?" — one word away (eval
            // 2026-08-12, sample 14, wrong on four runs out of four).
            //
            // The credit-card example sits SECOND on purpose: only the
            // first two reach the LLM prompt, so it also tells Stage 2
            // that card balances belong here rather than on card_limits.
            exampleQueries: [
                "What is my balance?", "What's my credit card balance?",
                "How much do I have in savings?", "How much is in my checking account?",
                "Show all my account balances",
                "bal?", "whats my bal", "how much money do i have"
            ],
            icon: "banknote",
            color: .green
        ),
        ToolDefinition(
            displayName: "convert_currency",
            category: .money,
            description: "Answer any currency conversion question: how much an amount, balance, or price is worth in another currency, at the current exchange rate.",
            notFor: "sending money abroad or exchanging cash (actions); the conversion QUESTION itself is always served by this tool. Also NOT for a question that merely mentions an amount without naming another currency — \"do I have enough to cover $5,000\" is a balance question, not a conversion",
            argumentHint: "a concrete amount like '$500' and the target currency code like 'EUR'; when converting an account balance, call account_balance FIRST and pass 'from account_balance' as the amount",
            // "How much is my balance in euros" earns its place in the
            // INDEX rather than the prompt — the entry only ever shows
            // two examples, and every text here is a vector Stage 1 can
            // match against.
            //
            // MEASURED, 2026-08-13. "How much is my checking balance in
            // euros, and what's my credit score?" did not retrieve this
            // tool at all: the shortlist came back account_balance 0.83,
            // fees_and_charges 0.81, credit_score 0.81, bank_statement
            // 0.80, card_limits 0.77, and convert_currency was not in it.
            // Stage 2 cannot select what Stage 1 never showed it — the
            // output grammar is built from the shortlist — so the reply
            // gave the balance in dollars and scored Completeness 2, the
            // only 2 in that batch. The existing examples all name a
            // literal amount ("$500 in euros") or the verb ("Convert my
            // savings balance"); none of them ask for a BALANCE in
            // another currency without saying "convert", which is the
            // most natural way to ask.
            exampleQueries: [
                "How much is $500 in euros?", "Convert my savings balance to GBP", "What's 200 dollars in yen?",
                "500 usd in eur", "200 dollars to yen",
                "How much is my balance in euros?", "what's my checking balance in GBP"
            ],
            icon: "arrow.left.arrow.right.circle",
            color: .mint
        ),
        ToolDefinition(
            displayName: "pending_payments",
            category: .payments,
            description: "Show payments and transactions that are currently processing and haven't cleared yet.",
            notFor: "future scheduled payments and autopay (use scheduled_payments), completed transactions (use list_transactions), or making or canceling a payment (action)",
            // PendingRequest takes an AccountType only. There is no
            // payee filter — MockBankAPIClient.pendingPayments returns
            // the same fixed list regardless of what it is asked for.
            argumentHint: "which account: checking, savings, credit card, or all",
            exampleQueries: [
                "Do I have any pending payments?", "Show payments that haven't cleared", "Any pending charges on my credit card?",
                "whats pending", "anything pending"
            ],
            icon: "clock.arrow.circlepath",
            color: .cyan
        ),
        ToolDefinition(
            displayName: "scheduled_payments",
            category: .payments,
            description: "Show upcoming scheduled payments, future transfers, and autopay settings.",
            notFor: "payments already processing (use pending_payments) or creating, changing, or canceling a payment (actions)",
            // ScheduledRequest takes an AccountType only. There is no
            // period or payee filter — MockBankAPIClient.scheduledPayments
            // returns the same fixed list regardless of what it is asked
            // for.
            argumentHint: "which account: checking, savings, credit card, or all",
            exampleQueries: [
                "What payments are scheduled for next week?", "Show my autopay settings", "When is my rent transfer going out?",
                "upcoming payments", "whats scheduled"
            ],
            icon: "calendar.badge.clock",
            color: .teal,
            promptExample: "When does my rent payment go out?"
        ),
        ToolDefinition(
            displayName: "card_limits",
            category: .cards,
            description: "Show the limits of the user's card: credit limit, daily ATM withdrawal limit, and spending limit.",
            // "the balance owed" belongs in notFor and NOWHERE ELSE in this
            // entry: notFor reaches the LLM prompt but is deliberately kept
            // out of the embedding index, so it can repel balance queries
            // at selection without attracting them at retrieval. Putting
            // the word "balance" in the description would do the opposite.
            notFor: "the balance owed on the card (use account_balance), the card number (use card_number), the credit score (use credit_score), or raising a limit (action)",
            argumentHint: "which card: debit, credit, or all when the question names none",
            exampleQueries: [
                "What's my credit limit?", "What's my daily ATM withdrawal limit?", "How much can I spend on my debit card?",
                "atm limit", "daily limit"
            ],
            icon: "gauge.with.needle",
            color: .orange,
            promptExample: "What's the max I can spend on my card?"
        ),
        ToolDefinition(
            displayName: "reward_points",
            category: .creditAndRewards,
            description: "Show the user's reward points balance and their cash value.",
            notFor: "a cash balance in checking, savings or a credit card (use account_balance) — a POINTS balance belongs here — or redeeming points (action)",
            argumentHint: "no parameters",
            exampleQueries: [
                "How many reward points do I have?", "What's my points balance worth?", "Show my rewards",
                "pts balance", "how many pts"
            ],
            icon: "star.circle",
            color: .yellow
        ),
        ToolDefinition(
            displayName: "get_dispute_status",
            category: .transactions,
            description: "Show the status of transaction disputes the user has ALREADY raised. Read-only: it cannot open, file, raise or escalate a dispute.",
            notFor: "raising a NEW dispute or reporting fraud (actions)",
            argumentHint: "the merchant of the disputed charge, or 'all'",
            exampleQueries: [
                "Any update on the charge I disputed?", "What's the status of my dispute?", "Show my open disputes",
                "dispute update", "whats happening with my dispute"
            ],
            icon: "exclamationmark.shield",
            color: .red,
            promptExample: "What's happening with the dispute I raised?"
        ),
        ToolDefinition(
            displayName: "branch_hours",
            category: .locations,
            description: "Show the opening hours of one branch, identified by its branch ID (e.g. 'BR-4417'). The ID comes from find_nearest_branch, which must run first — this tool does NOT accept a branch name.",
            notFor: "finding which branches exist (use find_nearest_branch); and never call this with a branch NAME the user said, because a name is not an ID — even 'the Main St branch' needs get_location and find_nearest_branch ahead of it to turn that name into an ID",
            argumentHint: "the branch ID from find_nearest_branch, e.g. 'BR-4417'",
            exampleQueries: [
                "(step 3 of, after find_nearest_branch) What time does the Main St branch close?",
                "(step 3 of, after find_nearest_branch) Is the airport branch open on Saturday?",
                "Branch opening hours", "branch timings", "main st branch hours"
            ],
            icon: "clock",
            color: .brown
        ),
        ToolDefinition(
            displayName: "interest_earned",
            category: .money,
            description: "Show the interest the user's accounts have earned.",
            notFor: "fees charged to the account (use fees_and_charges) or rates offered on new products",
            // InterestRequest takes an AccountType only — there is no
            // period parameter anywhere in it, and MockBankAPIClient
            // .interestEarned ignores the account too and always returns
            // the same fixed sentence. "and period, e.g. 'savings last
            // month'" described an argument this tool has never had.
            argumentHint: "which account: checking, savings, credit card, or all",
            exampleQueries: [
                "How much interest did my savings earn?", "What interest did I get this year?", "Show interest earned on my accounts",
                "interest earned", "savings interest"
            ],
            icon: "percent",
            color: .green
        ),
        ToolDefinition(
            displayName: "calculator",
            category: .utility,
            description: "Calculate a figure from numbers other tools have already returned: a total, an average, a difference, a percentage, a product, a quotient, the largest or smallest of a set, or a two-way comparison.",
            notFor: "fetching a figure no other tool has returned yet — this tool only computes from numbers already looked up, it cannot look up anything itself",
            argumentHint: "what to calculate (sum, average, difference, percentage, multiply, divide, max, or min) and the figures to use, copied exactly from another tool's result",
            exampleQueries: [
                "How much more did I spend at Starbucks than at Walmart?", "What's my average spend over the last three months?",
                "Is my checking balance enough to cover my rent?",
                "starbucks vs walmart spend", "avg spend last 3 months", "which month did i spend the most"
            ],
            icon: "plus.forwardslash.minus",
            color: .indigo
        )
    ]

    // Keyed by displayName: ToolName cases carry parameter values, so the
    // stable string identity is what links a routed call to its definition.
    static let byName: [String: ToolDefinition] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.displayName, $0) }
    )
}
