#!/bin/bash
set -e

echo "Laravel: Starting application setup..."
echo "Env: $APP_ENV"
echo -e "DB Host: $DB_HOST\n"

# Check if .env exists, if not create from .env.example
if [ ! -f .env ]; then
    echo "ENV: Creating .env file from .env.example..."
    cp .env.example .env
    echo -e "ENV: Created!\n\n"
fi

# Check if APP_KEY is set in environment variables (from Kubernetes Secret)
# If it is, update the .env file with the value from environment
if [ ! -z "${APP_KEY}" ]; then
    echo "APP_KEY: Found in environment variables, updating .env file..."
    # Escape special characters for sed
    ESCAPED_APP_KEY=$(printf '%s\n' "$APP_KEY" | sed -e 's/[\/&]/\\&/g')

    if grep -q "^APP_KEY=" .env; then
        # Replace existing APP_KEY
        sed -i "s/^APP_KEY=.*/APP_KEY=$ESCAPED_APP_KEY/" .env
    else
        # Add APP_KEY if it doesn't exist
        echo "APP_KEY=$APP_KEY" >> .env
    fi

    echo -e "APP_KEY: Updated\n\n"
fi

# Generate application key if not already set in .env
if ! grep -q "^APP_KEY=.\+" .env || grep -q "^APP_KEY=$" .env; then
    echo "APP_KEY: Generating a new application key..."
    php artisan key:generate --force
    echo -e "APP_KEY: Generated\n\n"
fi

################################
# Migrations
################################
if [ "$APP_ENV" != "testing" ] && [ -n "$DB_HOST" ]; then
    echo "Migrations"
    php artisan migrate --force
    echo -e "Migrations: Completed!\n\n"

    # Only run seeders in non-production environments or if explicitly enabled
    if [ "$APP_ENV" != "production" ] || [ "$RUN_SEEDERS" = "true" ]; then
        echo "Seeders"

        echo "Seeding root"
        php artisan db:seed --force

        echo "Seeding modules"
        php artisan module:seed --all --force
        echo -e "Seeders: Completed!\n\n"
    fi
fi

################################
# Misc
################################
# Set proper permissions
chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache
chmod -R 775 /var/www/html/storage /var/www/html/bootstrap/cache

# Clear any cached configuration that might have been baked into the image
# This prevents issues with absolute paths from the build environment
if [ "$APP_ENV" != "testing" ]; then
    echo "Cache: Clearing all cached data"
    php artisan optimize:clear
    echo ""
fi

################################
# Storage
################################
# Create storage link
echo "Storage: Create link"
mkdir -p storage/app/public
php artisan storage:link --force
echo ""

################################
# Telescope
################################
# Publish Telescope assets if Telescope is installed
if composer show laravel/telescope >/dev/null 2>&1; then
    echo "Telescope: Publish assets"
    php artisan vendor:publish --tag=telescope-assets --force
    echo ""
fi

################################
# Passport
################################
if composer show laravel/passport >/dev/null 2>&1; then
    if [ ! -f /var/www/html/storage/oauth-private.key ]; then
        echo "Passport: Generating keys..."
        php artisan passport:keys --force
        echo -e "Passport: Keys generated\n\n"
    fi

    # Set proper ownership and permissions for OAuth keys
    if [ -f /var/www/html/storage/oauth-private.key ]; then
        chown www-data:www-data /var/www/html/storage/oauth-private.key
        chmod 600 /var/www/html/storage/oauth-private.key
    fi

    if [ -f /var/www/html/storage/oauth-public.key ]; then
        chown www-data:www-data /var/www/html/storage/oauth-public.key
        chmod 600 /var/www/html/storage/oauth-public.key
    fi
fi

################################
# Misc
################################
# Optimize for production
if [ "$APP_ENV" = "production" ]; then
    echo "Optimizing for production..."
    php artisan optimize
    echo ""
fi

################################
# Scheduler
################################
if [[ "$1" == "php" ]] && [[ "$2" == "/var/www/html/artisan" ]] && [[ "$3" == "schedule:run" ]]; then
    echo "Scheduler: Running as scheduler pod - simplifying startup..."
    # Skip migrations and other heavy setup for scheduler
    exec php /var/www/html/artisan schedule:run
    echo ""
fi

echo -e "Laravel: Setup completed successfully!\n\n"

# Execute the main process (passed as arguments to this script)
exec "$@"
