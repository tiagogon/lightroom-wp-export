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
- HTTPS on the WordPress site
- Application Password generated in wp-admin → Users → Profile

### WordPress side

Add this line to your theme's `functions.php` (already done if using the tiagsspace theme):

```php
add_post_type_support( 'attachment', 'page-attributes' );
```

This exposes the `menu_order` field via the REST API, enabling gallery ordering.

## Installation

1. Clone or download this repo to your local machine (e.g. `~/Sites/lightroom-wp-export/`)
2. Open Lightroom Classic → File → Plug-in Manager
3. Click **Add** and navigate to the `lightroom-wp-export.lrplugin` folder
4. Click **Done**

## Setup

1. Go to File → Export
2. In the **WordPress Connection** section, enter:
   - **Site URL**: your WordPress site (e.g. `https://tiagsspace.com`)
   - **Username**: your WordPress username
   - **App Password**: an Application Password from wp-admin → Users → Profile → Application Passwords
3. Click **Test Connection** — you should see "Connected as {name} ✓"
4. Save as an export preset for reuse

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
