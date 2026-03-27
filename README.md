# Lightroom Classic → WordPress Export Plugin

Export photos from Lightroom Classic directly to WordPress posts (including custom post types) via the REST API.

## Features

- **New Post** or **Existing Post** — create a draft/published post, or append images to an existing one
- **All post types** — works with any REST-enabled post type (posts, pages, and custom types)
- **Gallery ordering** — images upload with `menu_order` matching your Lightroom selection order
- **Filename renaming** — files renamed to `{post-title}-001.jpg`, `{post-title}-002.jpg`, etc.
- **Featured image** — optionally set the first uploaded image as the post thumbnail
- **Status control** — choose Draft or Published for new posts; override status on existing posts
- **Export presets** — all settings save with Lightroom's standard preset system

## Requirements

- Lightroom Classic (SDK 6.0+)
- WordPress 5.6+ with REST API enabled
- HTTPS on the WordPress site (required for Application Passwords)
- A WordPress user account with Editor or Administrator role

### WordPress setup

The WordPress REST API is enabled by default since WordPress 4.7. If your site has the REST API disabled (via a plugin or custom code), you'll need to re-enable it for this plugin to work — ask your site administrator.

**1. Enable `menu_order` for attachments**

Add this line to your theme's `functions.php`:

```php
add_post_type_support( 'attachment', 'page-attributes' );
```

This exposes the `menu_order` field via the REST API, enabling gallery ordering. (Already done if using the tiagsspace theme.)

**2. Create an Application Password**

Application Passwords are built into WordPress since version 5.6. They let external apps authenticate without using your main login password.

1. Go to **wp-admin → Users → Profile** (or edit your own user)
2. Scroll down to the **Application Passwords** section
3. Enter a name like `Lightroom` in the "New Application Password Name" field
4. Click **Add New Application Password**
5. WordPress shows a password like `abcd EFGH 1234 ijkl MNOP 5678` — **copy it immediately** (it won't be shown again)
6. You'll paste this into the plugin settings in Lightroom

> **Note:** If you don't see the Application Passwords section, your site may not be using HTTPS, or a security plugin may have disabled the feature.

## Installation

1. Clone or download this repo to your local machine (e.g. `~/Sites/lightroom-wp-export/`)
2. Open Lightroom Classic → File → Plug-in Manager
3. Click **Add** and navigate to the `lightroom-wp-export.lrplugin` folder
4. Click **Done**

## Setup

1. Open Lightroom → **File → Plug-in Manager**
2. Select **WordPress Upload** from the list
3. In the **WordPress Connection** section, enter:
   - **Site URL**: your WordPress site (e.g. `https://tiags.space`)
   - **Username**: your WordPress username
   - **App Password**: the Application Password you created above (spaces are fine)
4. Click **Test Connection** — you should see "Connected as {name} ✓"
5. Click **Done**

The connection settings are shared across all exports — you only need to configure this once.

## Usage

### Export to a new post

1. Select photos in Lightroom
2. File → Export → choose your WordPress preset
3. Set destination to **New Post**
4. Pick a **Post Type**, enter a **Title**, choose **Status**
5. Click **Export**

### Export to an existing post

1. Select photos in Lightroom
2. File → Export → choose your WordPress preset
3. Set destination to **Existing Post**
4. Type at least 3 characters in **Search** and click **Search**
5. Select a post from the **Results** dropdown
6. Optionally override the **Status**
7. Click **Export**

Images are appended to the existing post — they don't replace existing gallery images.

## Limits

- Maximum 100 images per export
- Images upload sequentially (one at a time)
- Server-side upload limits (PHP `upload_max_filesize`) apply

## License

MIT
