;; Real Estate Escrow Services Contract
;; Manages secure holding of funds and documents during property transactions

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-ESCROW-NOT-FOUND (err u301))
(define-constant ERR-ESCROW-EXISTS (err u302))
(define-constant ERR-INVALID-STATE (err u303))
(define-constant ERR-INSUFFICIENT-FUNDS (err u304))
(define-constant ERR-INVALID-INPUT (err u305))
(define-constant ERR-DEADLINE-PASSED (err u306))

;; Data Variables
(define-data-var next-escrow-id uint u1)

;; Data Maps
(define-map escrow-accounts
  { escrow-id: uint }
  {
    property-id: uint,
    buyer: principal,
    seller: principal,
    agent: (optional principal),
    amount: uint,
    deposit-amount: uint,
    status: (string-ascii 20),
    created-at: uint,
    deadline: uint,
    conditions-met: uint,
    total-conditions: uint
  }
)

(define-map escrow-conditions
  { escrow-id: uint, condition-id: uint }
  {
    description: (string-ascii 200),
    required-by: principal,
    verified-by: (optional principal),
    verified-at: (optional uint),
    is-met: bool
  }
)

(define-map escrow-funds
  { escrow-id: uint }
  {
    total-deposited: uint,
    buyer-deposit: uint,
    seller-deposit: uint,
    agent-commission: uint,
    released: bool,
    release-date: (optional uint)
  }
)

(define-map escrow-documents
  { escrow-id: uint, doc-id: uint }
  {
    document-hash: (buff 32),
    document-type: (string-ascii 50),
    uploaded-by: principal,
    uploaded-at: uint,
    verified: bool
  }
)

;; Private Functions
(define-private (is-escrow-party (escrow-id uint) (party principal))
  (match (map-get? escrow-accounts { escrow-id: escrow-id })
    escrow (or (is-eq (get buyer escrow) party)
               (is-eq (get seller escrow) party)
               (match (get agent escrow)
                 agent (is-eq agent party)
                 false))
    false
  )
)

(define-private (all-conditions-met (escrow-id uint))
  (match (map-get? escrow-accounts { escrow-id: escrow-id })
    escrow (is-eq (get conditions-met escrow) (get total-conditions escrow))
    false
  )
)

(define-private (is-deadline-valid (deadline uint))
  (> deadline block-height)
)

;; Public Functions
(define-public (create-escrow (property-id uint) (buyer principal) (seller principal) (amount uint) (deadline uint))
  (let ((escrow-id (var-get next-escrow-id)))
    (asserts! (> property-id u0) ERR-INVALID-INPUT)
    (asserts! (not (is-eq buyer seller)) ERR-INVALID-INPUT)
    (asserts! (> amount u0) ERR-INVALID-INPUT)
    (asserts! (is-deadline-valid deadline) ERR-INVALID-INPUT)

    (map-set escrow-accounts
      { escrow-id: escrow-id }
      {
        property-id: property-id,
        buyer: buyer,
        seller: seller,
        agent: none,
        amount: amount,
        deposit-amount: u0,
        status: "created",
        created-at: block-height,
        deadline: deadline,
        conditions-met: u0,
        total-conditions: u0
      }
    )

    (map-set escrow-funds
      { escrow-id: escrow-id }
      {
        total-deposited: u0,
        buyer-deposit: u0,
        seller-deposit: u0,
        agent-commission: u0,
        released: false,
        release-date: none
      }
    )

    (var-set next-escrow-id (+ escrow-id u1))
    (ok escrow-id)
  )
)

(define-public (add-agent (escrow-id uint) (agent principal))
  (let ((escrow (unwrap! (map-get? escrow-accounts { escrow-id: escrow-id }) ERR-ESCROW-NOT-FOUND)))
    (asserts! (or (is-eq tx-sender (get buyer escrow)) (is-eq tx-sender (get seller escrow))) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status escrow) "created") ERR-INVALID-STATE)

    (map-set escrow-accounts
      { escrow-id: escrow-id }
      (merge escrow { agent: (some agent) })
    )
    (ok true)
  )
)

(define-public (deposit-funds (escrow-id uint) (deposit-amount uint))
  (let ((escrow (unwrap! (map-get? escrow-accounts { escrow-id: escrow-id }) ERR-ESCROW-NOT-FOUND))
        (funds (unwrap! (map-get? escrow-funds { escrow-id: escrow-id }) ERR-ESCROW-NOT-FOUND)))

    (asserts! (is-escrow-party escrow-id tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status escrow) "created") ERR-INVALID-STATE)
    (asserts! (> deposit-amount u0) ERR-INVALID-INPUT)
    (asserts! (< block-height (get deadline escrow)) ERR-DEADLINE-PASSED)

    (let ((new-total (+ (get total-deposited funds) deposit-amount))
          (new-buyer-deposit (if (is-eq tx-sender (get buyer escrow))
                               (+ (get buyer-deposit funds) deposit-amount)
                               (get buyer-deposit funds)))
          (new-seller-deposit (if (is-eq tx-sender (get seller escrow))
                                (+ (get seller-deposit funds) deposit-amount)
                                (get seller-deposit funds))))

      (map-set escrow-funds
        { escrow-id: escrow-id }
        (merge funds {
          total-deposited: new-total,
          buyer-deposit: new-buyer-deposit,
          seller-deposit: new-seller-deposit
        })
      )

      ;; Update escrow status if fully funded
      (if (>= new-total (get amount escrow))
        (map-set escrow-accounts
          { escrow-id: escrow-id }
          (merge escrow {
            status: "funded",
            deposit-amount: new-total
          })
        )
        true
      )

      (ok true)
    )
  )
)

(define-public (add-condition (escrow-id uint) (description (string-ascii 200)))
  (let ((escrow (unwrap! (map-get? escrow-accounts { escrow-id: escrow-id }) ERR-ESCROW-NOT-FOUND))
        (condition-id (+ (get total-conditions escrow) u1)))

    (asserts! (is-escrow-party escrow-id tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (or (is-eq (get status escrow) "created") (is-eq (get status escrow) "funded")) ERR-INVALID-STATE)
    (asserts! (> (len description) u0) ERR-INVALID-INPUT)

    (map-set escrow-conditions
      { escrow-id: escrow-id, condition-id: condition-id }
      {
        description: description,
        required-by: tx-sender,
        verified-by: none,
        verified-at: none,
        is-met: false
      }
    )

    (map-set escrow-accounts
      { escrow-id: escrow-id }
      (merge escrow { total-conditions: condition-id })
    )

    (ok condition-id)
  )
)

(define-public (verify-condition (escrow-id uint) (condition-id uint))
  (let ((escrow (unwrap! (map-get? escrow-accounts { escrow-id: escrow-id }) ERR-ESCROW-NOT-FOUND))
        (condition (unwrap! (map-get? escrow-conditions { escrow-id: escrow-id, condition-id: condition-id }) ERR-ESCROW-NOT-FOUND)))

    (asserts! (is-escrow-party escrow-id tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (not (get is-met condition)) ERR-INVALID-STATE)
    (asserts! (< block-height (get deadline escrow)) ERR-DEADLINE-PASSED)

    (map-set escrow-conditions
      { escrow-id: escrow-id, condition-id: condition-id }
      (merge condition {
        verified-by: (some tx-sender),
        verified-at: (some block-height),
        is-met: true
      })
    )

    (let ((new-conditions-met (+ (get conditions-met escrow) u1)))
      (map-set escrow-accounts
        { escrow-id: escrow-id }
        (merge escrow { conditions-met: new-conditions-met })
      )

      ;; Check if all conditions are met
      (if (is-eq new-conditions-met (get total-conditions escrow))
        (map-set escrow-accounts
          { escrow-id: escrow-id }
          (merge escrow { status: "ready-to-close" })
        )
        true
      )
    )

    (ok true)
  )
)

(define-public (release-funds (escrow-id uint))
  (let ((escrow (unwrap! (map-get? escrow-accounts { escrow-id: escrow-id }) ERR-ESCROW-NOT-FOUND))
        (funds (unwrap! (map-get? escrow-funds { escrow-id: escrow-id }) ERR-ESCROW-NOT-FOUND)))

    (asserts! (is-escrow-party escrow-id tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status escrow) "ready-to-close") ERR-INVALID-STATE)
    (asserts! (not (get released funds)) ERR-INVALID-STATE)
    (asserts! (all-conditions-met escrow-id) ERR-INVALID-STATE)

    (map-set escrow-funds
      { escrow-id: escrow-id }
      (merge funds {
        released: true,
        release-date: (some block-height)
      })
    )

    (map-set escrow-accounts
      { escrow-id: escrow-id }
      (merge escrow { status: "completed" })
    )

    (ok true)
  )
)

;; Read-only Functions
(define-read-only (get-escrow (escrow-id uint))
  (map-get? escrow-accounts { escrow-id: escrow-id })
)

(define-read-only (get-escrow-funds (escrow-id uint))
  (map-get? escrow-funds { escrow-id: escrow-id })
)

(define-read-only (get-condition (escrow-id uint) (condition-id uint))
  (map-get? escrow-conditions { escrow-id: escrow-id, condition-id: condition-id })
)

(define-read-only (get-escrow-status (escrow-id uint))
  (match (map-get? escrow-accounts { escrow-id: escrow-id })
    escrow (some (get status escrow))
    none
  )
)

(define-read-only (is-ready-to-close (escrow-id uint))
  (match (map-get? escrow-accounts { escrow-id: escrow-id })
    escrow (and (is-eq (get status escrow) "ready-to-close")
                (all-conditions-met escrow-id))
    false
  )
)

(define-read-only (get-next-escrow-id)
  (var-get next-escrow-id)
)
