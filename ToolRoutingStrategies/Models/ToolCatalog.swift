import SwiftUI

// MARK: - Tool Catalog
//
// The full set of app tools available to every routing strategy.
// Both the UI (tool list) and the routers (prompt/embedding text)
// read from here, so the two can never drift out of sync.

enum ToolCatalog {
    static let all: [ToolDefinition] = [
        ToolDefinition(
            displayName: "list_transactions",
            category: .transactions,
            description: "List the user's transactions from the recent past.",
            notFor: "merchant-specific searches (use search_transactions), payments that haven't cleared yet (use pending_payments), or a full statement document (use bank_statement)",
            argumentHint: "how many past days of transactions to show, as a digit, e.g. '7'; use '7' if the user doesn't specify",
            exampleQueries: ["Show my transactions from the last week", "What did I spend in the past 3 days?", "List this month's transactions"],
            icon: "list.bullet.rectangle",
            color: .blue
        ),
        ToolDefinition(
            displayName: "search_transactions",
            category: .transactions,
            description: "Search the user's past transactions for a specific merchant — including how much they spent at a store or service.",
            notFor: "a general recent listing without a merchant (use list_transactions)",
            argumentHint: "the merchant name, e.g. 'Starbucks'",
            exampleQueries: ["What did I spend at Starbucks?", "Show my Amazon purchases", "Any charges from Netflix?"],
            icon: "magnifyingglass",
            color: .gray
        ),
        ToolDefinition(
            displayName: "routing_number",
            category: .accounts,
            description: "Show the routing number of the user's account.",
            notFor: "the account number itself (use account_number) or card numbers (use card_number)",
            argumentHint: "which account: checking or savings",
            exampleQueries: ["What's my routing number?", "I need the routing number for a wire transfer", "Routing number for my checking account"],
            icon: "number.circle",
            color: .teal
        ),
        ToolDefinition(
            displayName: "account_number",
            category: .accounts,
            description: "Show the user's account number.",
            notFor: "the routing number (use routing_number) or card numbers (use card_number)",
            argumentHint: "which account: checking or savings",
            exampleQueries: ["What's my account number?", "Show my savings account number", "I need my checking account number for direct deposit"],
            icon: "123.rectangle",
            color: .indigo
        ),
        ToolDefinition(
            displayName: "card_number",
            category: .cards,
            description: "Show the number of the user's debit or credit card.",
            notFor: "blocking, freezing, or replacing a card — those are actions and must be sent to backend",
            argumentHint: "which card: debit or credit",
            exampleQueries: ["What's my debit card number?", "Show my credit card number", "I need my card number"],
            icon: "creditcard",
            color: .purple
        ),
        ToolDefinition(
            displayName: "bank_statement",
            category: .accounts,
            description: "Show the user's bank statement for a given month or period.",
            notFor: "listing individual transactions inline (use list_transactions)",
            argumentHint: "the period and account in plain text, e.g. 'June', 'last month, checking'",
            exampleQueries: ["Get my bank statement for June", "Show last month's statement", "Download my checking account statement"],
            icon: "doc.text",
            color: .brown
        ),
        ToolDefinition(
            displayName: "credit_score",
            category: .creditAndRewards,
            description: "Show the user's current credit score.",
            notFor: "advice on improving the score or disputing it — send to backend",
            argumentHint: "no parameters",
            exampleQueries: ["What's my credit score?", "Show my current credit score", "Has my credit score changed?"],
            icon: "gauge",
            color: .mint
        ),
        ToolDefinition(
            displayName: "get_location",
            category: .locations,
            description: "Get the user's current location. Call this FIRST when the user says 'near me' or 'nearest' without naming a place, then pass its result to find_branch or find_atm.",
            notFor: "requests that already name a place, city, or zip code — pass those directly to find_branch or find_atm",
            argumentHint: "no parameters",
            exampleQueries: ["(step 1 of) Find an ATM near me", "(step 1 of) Where's the closest branch?"],
            icon: "location.circle",
            color: .pink
        ),
        ToolDefinition(
            displayName: "find_branch",
            category: .locations,
            description: "Find bank branches at a given location.",
            notFor: "ATMs (use find_atm) or booking an appointment at a branch — that is an action and must be sent to backend",
            argumentHint: "the place: a city, zip code, or 'current location' when it comes from get_location",
            exampleQueries: ["Is there a branch in downtown?", "Nearest branch to 94103", "Find a branch near me"],
            icon: "mappin.and.ellipse",
            color: .red
        ),
        ToolDefinition(
            displayName: "find_atm",
            category: .locations,
            description: "Find ATMs at a given location.",
            notFor: "branches with tellers (use find_branch) or withdrawal limit changes — those must be sent to backend",
            argumentHint: "the place: a city, zip code, or 'current location' when it comes from get_location",
            exampleQueries: ["Find the nearest ATM", "Any ATMs in the airport?", "ATMs near 94103"],
            icon: "dollarsign.square",
            color: .yellow
        ),
        ToolDefinition(
            displayName: "fees_and_charges",
            category: .money,
            description: "Show the fees and charges on the user's account, such as the monthly service fee.",
            notFor: "waiving or disputing a fee — those are actions and must be sent to backend",
            argumentHint: "which fee or account, e.g. 'monthly service fee', 'all charges on checking'",
            exampleQueries: ["What's my monthly service fee?", "What charges are on my account?", "Why am I being charged a service fee?"],
            icon: "dollarsign.circle",
            color: .orange
        ),
        ToolDefinition(
            displayName: "account_balance",
            category: .accounts,
            description: "Show the current balance of the user's accounts (checking, savings, credit card).",
            notFor: "past transactions (use list_transactions) or payments still processing (use pending_payments)",
            argumentHint: "which account: checking, savings, credit card, or all",
            exampleQueries: ["What is my balance?", "How much do I have in savings?", "Show all my account balances"],
            icon: "banknote",
            color: .green
        ),
        ToolDefinition(
            displayName: "convert_currency",
            category: .money,
            description: "Answer any currency conversion question: how much an amount, balance, or price is worth in another currency, at the current exchange rate.",
            notFor: "sending money abroad or exchanging cash — those are actions and must be sent to backend; the conversion QUESTION itself is always served by this tool",
            argumentHint: "a concrete amount like '$500' and the target currency code like 'EUR'; when converting an account balance, call account_balance FIRST and pass 'from account_balance' as the amount",
            exampleQueries: ["How much is $500 in euros?", "Convert my savings balance to GBP", "What's 200 dollars in yen?"],
            icon: "arrow.left.arrow.right.circle",
            color: .mint
        ),
        ToolDefinition(
            displayName: "pending_payments",
            category: .payments,
            description: "Show payments and transactions that are currently processing and haven't cleared yet.",
            notFor: "future scheduled payments and autopay (use scheduled_payments), completed transactions (use list_transactions), or making or canceling a payment — those must be sent to backend",
            argumentHint: "which account or payee, or 'all'",
            exampleQueries: ["Do I have any pending payments?", "Show payments that haven't cleared", "Any pending charges on my credit card?"],
            icon: "clock.arrow.circlepath",
            color: .cyan
        ),
        ToolDefinition(
            displayName: "scheduled_payments",
            category: .payments,
            description: "Show upcoming scheduled payments, future transfers, and autopay settings.",
            notFor: "payments already processing (use pending_payments) or creating, changing, or canceling a payment — those are actions and must be sent to backend",
            argumentHint: "the period or payee, e.g. 'next week', 'electricity bill', or 'all'",
            exampleQueries: ["What payments are scheduled for next week?", "Show my autopay settings", "When is my rent transfer going out?"],
            icon: "calendar.badge.clock",
            color: .teal,
            promptExample: "When does my rent payment go out?"
        ),
        ToolDefinition(
            displayName: "card_limits",
            category: .cards,
            description: "Show the limits of the user's card: credit limit, daily ATM withdrawal limit, and spending limit.",
            notFor: "the card number (use card_number), the credit score (use credit_score), or raising a limit — that is an action and must be sent to backend",
            argumentHint: "which card: debit or credit",
            exampleQueries: ["What's my credit limit?", "What's my daily ATM withdrawal limit?", "How much can I spend on my debit card?"],
            icon: "gauge.with.needle",
            color: .orange,
            promptExample: "What's the max I can spend on my card?"
        ),
        ToolDefinition(
            displayName: "reward_points",
            category: .creditAndRewards,
            description: "Show the user's reward points balance and their cash value.",
            notFor: "money balances (use account_balance) or redeeming points — that is an action and must be sent to backend",
            argumentHint: "no parameters",
            exampleQueries: ["How many reward points do I have?", "What's my points balance worth?", "Show my rewards"],
            icon: "star.circle",
            color: .yellow
        ),
        ToolDefinition(
            displayName: "dispute_status",
            category: .transactions,
            description: "Show the status of transaction disputes the user has already raised.",
            notFor: "raising a NEW dispute or reporting fraud — those are actions and must be sent to backend",
            argumentHint: "the merchant of the disputed charge, or 'all'",
            exampleQueries: ["Any update on the charge I disputed?", "What's the status of my dispute?", "Show my open disputes"],
            icon: "exclamationmark.shield",
            color: .red,
            promptExample: "What's happening with the dispute I raised?"
        ),
        ToolDefinition(
            displayName: "branch_hours",
            category: .locations,
            description: "Show the opening hours of a branch the user names, e.g. 'the Main St branch' or 'the airport branch'.",
            notFor: "finding which branches exist — when the user names the branch, call this tool DIRECTLY with that name; only chain get_location and find_branch first when no branch is named",
            argumentHint: "the branch name, e.g. 'Main St', or 'from find_branch' when it comes from an earlier step",
            exampleQueries: ["What time does the Main St branch close?", "Is the airport branch open on Saturday?", "Branch opening hours"],
            icon: "clock",
            color: .brown
        ),
        ToolDefinition(
            displayName: "interest_earned",
            category: .money,
            description: "Show the interest the user's accounts have earned.",
            notFor: "fees charged to the account (use fees_and_charges) or rates offered on new products — those go to the backend",
            argumentHint: "which account and period, e.g. 'savings last month'",
            exampleQueries: ["How much interest did my savings earn?", "What interest did I get this year?", "Show interest earned on my accounts"],
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
