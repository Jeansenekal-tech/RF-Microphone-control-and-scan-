# Licensing setup

Unique AV RF Scan Co-ord uses [Keygen](https://keygen.sh) for licences:

* **60-day trial**, one per Mac. Reinstalling doesn't restart it, because the trial is tied to the Mac's hardware fingerprint on the server.
* **One Mac per licence.** A second Mac is refused with "Licence in use on another Mac".
* **Moving to a new Mac:** use *Project › Licence › Deactivate this Mac*. If the old Mac is lost or broken, choose
  **Move licence to this Mac** on the new one. The old Mac locks at its next check-in, or at the latest after
  30 days offline.
* **Offline use:** a signed licence file lets the app run for **30 days** without internet.
* **Locked when there's no valid licence:** the app shows only the licence screen. It's checked at launch, so a
  licence problem found while the app is running never stops a show. The app locks on the next launch.

Builds without licensing settings (local `./build_app.sh`, CI) run as unlocked **developer builds**. That's why
the source repository must be private.

---

## 1. GitHub

1. **Make this repository private:** *Settings › General › Danger Zone › Change visibility*.
2. **Create a public releases repository**, e.g. `Jeansenekal-tech/unique-av-rf-releases`. Tick *Add a README*
   so it isn't empty. It only holds the downloadable app.
3. Create a **fine-grained personal access token**: *GitHub › Settings › Developer settings › Fine-grained tokens*.
   Give it *Only select repositories → the releases repo* and *Repository permissions → Contents: Read and write*.
4. In **this** repo, open *Settings › Secrets and variables › Actions*:
   * Secret **`RELEASES_TOKEN`** = the token from step 3
   * Variable **`RELEASES_REPO`** = `Jeansenekal-tech/unique-av-rf-releases`

## 2. Keygen

1. Create an account at keygen.sh and a **Product** called "Unique AV RF Scan Co-ord".
2. Create two **Policies** for that product. The names below are Keygen's policy settings.

   | Setting | **Pro** (paid) | **Trial** |
   |---|---|---|
   | Duration | none (perpetual) or 1 year for subscriptions | **60 days** (5184000 s) |
   | Max machines | **1** | **1** |
   | Floating | off | off |
   | Strict | on | on |
   | Protected | **off** (the app activates and deactivates Macs itself) | **off** |
   | Authentication strategy | **LICENSE** | **LICENSE** |
   | Machine uniqueness | UNIQUE_PER_LICENSE | **UNIQUE_PER_POLICY** (one trial per Mac, ever) |
   | Expiration strategy | RESTRICT_ACCESS | RESTRICT_ACCESS |
   | Require fingerprint scope | on | on |

3. Copy these from Keygen's settings into this repo's **Actions variables**:
   * **`KEYGEN_ACCOUNT_ID`**: your account ID
   * **`KEYGEN_PUBLIC_KEY`**: the account's **Ed25519 public verify key** (64 hex characters)
4. Create a **Product token** for the trial worker. It's secret, so it goes only into Cloudflare, never into the app or GitHub.

## 3. Trial worker (Cloudflare, free tier)

The app asks this small worker for a trial key, because creating licences needs the secret Keygen token.

```bash
cd licensing/trial-worker
```

```bash
npx wrangler login
```

```bash
npx wrangler secret put KEYGEN_ACCOUNT_ID
```

```bash
npx wrangler secret put KEYGEN_TOKEN
```

```bash
npx wrangler secret put KEYGEN_TRIAL_POLICY_ID
```

```bash
npx wrangler deploy
```

Put the URL it prints (e.g. `https://uniqueav-rf-trial.<you>.workers.dev`) in the variable **`TRIAL_URL`**.

## 4. Selling

Set the variable **`PURCHASE_URL`** to your shop or checkout page. The *Buy a licence* buttons open it.

After a payment, create a licence on the **Pro** policy in Keygen and email the key to the customer. Keygen can
do this automatically when connected to Stripe or another shop with webhooks. Set that up in Keygen when you're
ready to sell at volume.

## 5. Releasing

Raise `CFBundleShortVersionString` in `Resources/Info.plist` and push to `main`. The *Release* workflow tests,
builds a universal app with the licensing settings compiled in, and publishes it to `RELEASES_REPO`. Installed
copies update themselves.

The workflow refuses to publish an **unlicensed** build unless you set `ALLOW_UNLICENSED_RELEASE` = `true`.
It also refuses to publish from a private repo when `RELEASES_REPO` isn't set.

## Support tasks (Keygen dashboard)

| Customer says | Do this |
|---|---|
| "My Mac died / was stolen" | Tell them to choose **Move licence to this Mac** on the new Mac. Or, in Keygen: *Licenses › their licence › Machines › delete*. |
| "Can I have a longer trial?" | Open their trial licence and extend its expiry. |
| "Refund" | Suspend or delete the licence. The Mac locks at its next check-in (at most 30 days offline). |

## Honest limits

* Any app can be cracked by someone patient enough to patch the binary. This scheme stops casual sharing and
  trial resets. For stronger protection, sign and notarize releases with an Apple **Developer ID** ($99/year),
  which also removes the "unidentified developer" warning for customers.
* A Mac kept offline keeps working for up to 30 days after its licence is moved or revoked.
