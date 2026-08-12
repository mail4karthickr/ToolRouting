import SwiftUI

// MARK: - Tool Catalog
//
// The full set of app tools available to every routing strategy.
// Both the UI (tool list) and the routers (prompt/embedding text)
// read from here, so the two can never drift out of sync.
//
// `exampleQueries` DELIBERATELY MIXES TWO REGISTERS, and the order is
// load-bearing:
//
//   first  well-formed sentences — "What is my balance?"
//   then   how people actually type — "bal?", "this weeks txns"
//
// Both halves are embedded. ToolIndex vectorises the description and
// EACH example separately and scores a tool by its best match, so a
// colloquial entry raises the ceiling for colloquial phrasing without
// dragging the tool's other vectors toward it. Sentences alone left a
// measurable gap: real queries arrive lowercase, abbreviated and
// unpunctuated, and the index had no vector anywhere near them.
//
// The ORDER matters because only the first two reach the LLM prompt
// (LLMRouter.entry caps at two, for context budget). The full sentences
// are the better teaching examples for a model choosing between five
// candidates, so they stay in front; the abbreviations are for retrieval,
// which reads all of them. Append colloquial entries, never prepend.
//
// Adding or editing any of this text changes the index fingerprint, so
// the next launch re-embeds the catalog once before serving a request.

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
            description: "Show the routing number of the user's account.",
            notFor: "the account number itself (use account_number) or card numbers (use card_number)",
            argumentHint: "which account: checking or savings",
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
            argumentHint: "which account: checking or savings",
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
            notFor: "advice on improving or disputing the score",
            argumentHint: "no parameters",
            exampleQueries: [
                "What's my credit score?", "Show my current credit score", "Has my credit score changed?",
                "my fico", "fico score", "credit score"
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
            argumentHint: "which fee or account, e.g. 'monthly service fee', 'all charges on checking'",
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
            exampleQueries: [
                "How much is $500 in euros?", "Convert my savings balance to GBP", "What's 200 dollars in yen?",
                "500 usd in eur", "200 dollars to yen"
            ],
            icon: "arrow.left.arrow.right.circle",
            color: .mint
        ),
        ToolDefinition(
            displayName: "pending_payments",
            category: .payments,
            description: "Show payments and transactions that are currently processing and haven't cleared yet.",
            notFor: "future scheduled payments and autopay (use scheduled_payments), completed transactions (use list_transactions), or making or canceling a payment (action)",
            argumentHint: "which account or payee, or 'all'",
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
            argumentHint: "the period or payee, e.g. 'next week', 'electricity bill', or 'all'",
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
            argumentHint: "which account and period, e.g. 'savings last month'",
            exampleQueries: [
                "How much interest did my savings earn?", "What interest did I get this year?", "Show interest earned on my accounts",
                "interest earned", "savings interest"
            ],
            icon: "percent",
            color: .green
        )
    ]

    // Keyed by displayName: ToolName cases carry parameter values, so the
    // stable string identity is what links a routed call to its definition.
    static let byName: [String: ToolDefinition] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.displayName, $0) }
    )
}
