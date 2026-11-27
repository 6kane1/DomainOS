#!/usr/bin/env python3
"""Stripe -> Discord: a direct message to the developer for every paid service (28.11.2026).

Runs inside the Discord bot workflow every ~10 minutes. It reads the Checkout Sessions of the last 3 days with a
RESTRICTED Stripe key (STRIPE_KEY, only "Checkout Sessions: Read"), and for each paid session that is not yet in the
developer's DM history it sends one message: bundle, amount, the buyer's Discord name, name and email. The DM history
is the only state (the session id is in each message), so nothing about sales is stored in this public repository and
a late or skipped run never loses a payment. No key: the step does nothing.
"""
import json, os, sys, time, urllib.error, urllib.parse, urllib.request

DEV = os.environ.get('DEV_DISCORD_ID', '528659324193734659')
API = 'https://discord.com/api/v10'
DAYS = 3


def stripe(path, params):
    key = os.environ['STRIPE_KEY']
    url = 'https://api.stripe.com/v1/' + path + '?' + urllib.parse.urlencode(params, doseq=True)
    req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + key, 'User-Agent': 'DomainOS-bot'})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def discord(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={'Authorization': 'Bot ' + os.environ['DISCORD_TOKEN'], 'Content-Type': 'application/json',
                                          'User-Agent': 'DomainOS-bot (https://github.com/6kane1/DomainOS, 1)'})
    for _ in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                t = r.read(); return json.loads(t) if t else None
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(float(json.loads(e.read() or b'{}').get('retry_after', 2))); continue
            raise


def sessions():
    since = int(time.time()) - DAYS * 86400
    out, after = [], None
    while True:
        p = {'limit': 100, 'created[gte]': since, 'status': 'complete', 'expand[]': 'data.line_items'}
        if after: p['starting_after'] = after
        page = stripe('checkout/sessions', p)
        out += page.get('data', [])
        if not page.get('has_more') or not page['data']: return out
        after = page['data'][-1]['id']


def field(s, label):
    for f in s.get('custom_fields') or []:
        if label.lower() in ((f.get('label') or {}).get('custom') or f.get('key') or '').lower():
            return ((f.get('text') or {}).get('value') or '').strip()
    return ''


def main():
    if not os.environ.get('STRIPE_KEY'):
        print('No STRIPE_KEY: payment notices are off.'); return 0
    dm = discord('POST', '/users/@me/channels', {'recipient_id': DEV})['id']
    seen = ''.join(m.get('content', '') for m in discord('GET', f'/channels/{dm}/messages?limit=100') or [])
    sent = 0
    for s in sorted(sessions(), key=lambda x: x['created']):
        if s.get('payment_status') not in ('paid', 'no_payment_required') or s['id'] in seen: continue
        items = ', '.join(li.get('description') or '?' for li in (s.get('line_items') or {}).get('data', [])) or '?'
        amount = f"{(s.get('amount_total') or 0) / 100:.2f} {(s.get('currency') or '').upper()}"
        cd = s.get('customer_details') or {}
        test = '' if s.get('livemode') else ' (ТЕСТ)'
        who = field(s, 'discord') or 'не указан'
        text = (f"💳 **Оплата{test}: {items}**, {amount}\n"
                f"Discord: **{who}**\n"
                f"Имя: {cd.get('name') or '-'} · email: {cd.get('email') or '-'} · страна: {(cd.get('address') or {}).get('country') or '-'}\n"
                f"{'Подписка' if s.get('mode') == 'subscription' else 'Разовая оплата'} · {time.strftime('%d.%m %H:%M UTC', time.gmtime(s['created']))}\n"
                f"-# {s['id']}")
        discord('POST', f'/channels/{dm}/messages', {'content': text[:1900], 'allowed_mentions': {'parse': []}})
        sent += 1; time.sleep(1)
    print(f'Payment notices sent: {sent}')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:  # never break the bot run because of payments
        print('Payment notices failed:', type(e).__name__, str(e)[:200]); sys.exit(0)
