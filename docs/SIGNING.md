# Signing MPC Loader so it can be shared

Two things let anyone download MPC Loader and open it without a warning:

- **Signing** proves who made the app.
- **Notarisation** is Apple checking it for malicious software.

The build does both by itself once your certificate and Apple details are stored in GitHub. Until then, builds are unsigned and macOS warns about them, as now.

Setting it up is a one-off job. It takes about half an hour, plus the time Apple takes to approve your developer membership.

## What you need

- Your Mac.
- A paid Apple Developer Program membership.
- Owner access to this repository on GitHub.

## 1. Join the Apple Developer Program

Go to [developer.apple.com/programs/enroll](https://developer.apple.com/programs/enroll/) and enrol as an individual with your Apple Account. Approval can take up to two days. As an individual, people see your own name as the developer.

## 2. Make a Developer ID certificate

The build signs the app with this certificate. It comes in two halves: a certificate from Apple, and a private key that your Mac creates and keeps.

1. On your Mac, open **Keychain Access**. Press ⌘Space and type its name to find it.
2. From the menu bar, choose **Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority**.
3. Enter your email address and name. Leave *CA Email Address* empty, choose **Saved to disk**, click **Continue** and save the file to your Desktop.
4. In your browser, open [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/list) and click **+**.
5. Choose **Developer ID Application** and click **Continue**. If it asks for a profile type, choose **G2 Sub-CA**. Upload the file from your Desktop and click **Continue**.
6. Click **Download**, then double-click the downloaded file. Keychain Access adds the certificate.

If the menus don't match your version of macOS, Xcode can do the same job: **Xcode → Settings → Accounts**, select your Apple Account, click **Manage Certificates**, then **+ → Developer ID Application**.

## 3. Export the certificate with its key

1. In Keychain Access, select the **login** keychain, then the **My Certificates** tab.
2. Find **Developer ID Application: *your name* (*your Team ID*)**. Right-click it, choose **Export**, pick the **.p12** format and save it to your Desktop as `MPC-Loader-signing.p12`.
3. When asked, set a password for the file. You'll need it in step 6.

GitHub stores secrets as text, so the file is turned into text when you add it in step 6.

## 4. Make an app-specific password

Notarisation signs in to Apple as you. An app-specific password lets the build do that without your real password, and you can withdraw it at any time.

1. Go to [account.apple.com](https://account.apple.com) and sign in.
2. Under **Sign-In and Security**, choose **App-Specific Passwords**, click **+** and name it `MPC Loader notarisation`.
3. Keep the password page open for step 6. Apple only shows it once.

## 5. Find your Team ID

Open [developer.apple.com/account](https://developer.apple.com/account) and look under **Membership details**. The Team ID is 10 letters and numbers. It also appears in brackets at the end of the certificate's name.

## 6. Store the details in GitHub

GitHub keeps these encrypted. Only the build can read them, and nobody can view them afterwards, including you. Never paste them anywhere else: not into a chat, an issue or a file in the repository.

1. Open the repository on GitHub and go to **Settings → Secrets and variables → Actions**.
2. For each row below, click **New repository secret**, enter the name exactly as shown, and paste the value.

| Name | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | The certificate as text. In Terminal, run `base64 -i ~/Desktop/MPC-Loader-signing.p12 \| pbcopy` to copy it, then paste. |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set in step 3. |
| `APPLE_ID` | The email address of your Apple Account. |
| `APPLE_APP_PASSWORD` | The app-specific password from step 4. |
| `APPLE_TEAM_ID` | Your Team ID from step 5. |

3. Delete `MPC-Loader-signing.p12` and the certificate request from your Desktop. The certificate stays safely in your keychain.

## 7. Check it works

On GitHub, open **Actions → Build → Run workflow**, choose **main** and run it. In the *Mac app* job, the **Sign and notarise** step should turn green. Apple usually answers within a few minutes, but it can take longer. From then on, every build of main is signed and notarised, and its *MPC-Loader-dmg* download opens without a warning.

## Publishing a version

Each published version gets its own entry on the repository's **Releases** page, with a disk image anyone can download without a GitHub account. A version is published by giving it a tag such as `v1.0.0`. Either:

- On GitHub, go to **Releases → Draft a new release**, type a new tag such as `v1.0.0`, add a title and click **Publish release**. The build then adds the signed disk image to it, usually within 20 minutes.
- Or ask Claude to publish a version.

The tag sets the version number the app shows in **MPC Loader → About MPC Loader**. A version can only be published once signing is set up. Until then, the build stops with a message saying so.

## What people see

They download `MPC-Loader-1.0.0.dmg`, open it, drag **MPC Loader** onto the **Applications** folder beside it, and open it like any other app, with no warning.

## If something goes wrong

The **Sign and notarise** step explains what failed. The usual causes:

- **A secret is missing:** a name in step 6 doesn't match exactly.
- **The certificate couldn't be opened:** the certificate text or its password is wrong. Export it and add it again.
- **No Developer ID Application certificate was found:** a different kind of certificate was exported, such as *Apple Development*. Export the Developer ID Application one.
- **Apple didn't accept it:** if the message mentions signing in, check the Apple Account email, app-specific password and Team ID. Otherwise, Apple's reasons are listed in the step's output.

The certificate lasts five years. When it expires, repeat steps 2, 3 and 6.
