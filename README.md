# Speed's Auction Card Portal

Prints Speed's Auto Auction bidder cards on the AlphaCard PRO 500 (CR80, one-sided). Replaces CloudBadging.

- **`index.html`** — the whole portal (single file). Deployed on Vercel.
- **Supabase project:** `speeds-auction-card-portal` (West US / Oregon)

## What it does
- **Weekly Import** — upload the Tops bidder CSV. Matches on bidder number: same name = renewal, different name = asks before replacing and moves the old bidder to the Archive. Tick "full Tops bidder list" to sync everyone without issuing cards.
- **Photos** — load photos from the memory card, hover to magnify the card in the photo, type the number. Undo / remove / Not in Tops.
- **Not in Tops** — photographed people missing from Tops; prints on cards or paper.
- **Print Queue** — prints cards (3.375 × 2.125 in) to the AlphaCard printer.
- **Records / Archive** — every bidder with full history (added, renewed, printed, photo, edited, archived).
- **Users** (admins) — add staff and set permissions. **Settings** — card term, barcode, logo, one-time CloudBadging import.

Driver's license numbers and addresses are never stored.

## Supabase setup (already done — kept for reference)
Run in the SQL Editor, in order:
1. `supabase/01_bidder_cards_setup.sql` — tables, archive, storage bucket
2. `supabase/02_staff_permissions.sql` — staff logins and permissions
3. `supabase/03_bidder_history.sql` — automatic bidder history

Edge Function `staff-admin` (`supabase/functions/staff-admin/index.ts`) creates logins and resets passwords for admins. "Verify JWT with legacy secret" is turned off; the function checks the caller itself.

Public sign-ups are turned off in Supabase Auth — staff are added from the portal's Users page.
