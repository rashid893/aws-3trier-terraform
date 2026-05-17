#!/bin/bash
set -euo pipefail

exec > /var/log/user-data.log 2>&1
echo "=== User data script starting at $(date) ==="

# --- System packages ---
dnf update -y
dnf install -y python3 python3-pip python3-devel git gcc mariadb105-devel pkgconfig

# Determine python binary
PYTHON_BIN=$(command -v python3)
echo "Using Python: $PYTHON_BIN ($($PYTHON_BIN --version))"

# --- Create app user ---
useradd -m -s /bin/bash appuser || true

# --- Application directory ---
APP_DIR="/opt/django-app"
mkdir -p "$APP_DIR"

# --- Virtual environment ---
$PYTHON_BIN -m venv "$APP_DIR/venv"
source "$APP_DIR/venv/bin/activate"
pip install --upgrade pip

# --- Requirements ---
cat > "$APP_DIR/requirements.txt" << 'REQUIREMENTS'
django>=4.2,<5.0
gunicorn>=21.2
mysqlclient>=2.2
django-health-check>=3.18
whitenoise>=6.5
REQUIREMENTS

pip install -r "$APP_DIR/requirements.txt"

# --- Create Django project ---
cd "$APP_DIR"

if [ ! -f "$APP_DIR/manage.py" ]; then
  django-admin startproject config .
  python manage.py startapp myapp
fi

# --- Django settings override ---
cat > "$APP_DIR/config/settings_prod.py" << 'SETTINGS'
import os
from config.settings import *

DEBUG = False
ALLOWED_HOSTS = ['*']

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': os.environ.get('DB_NAME', 'appdb'),
        'USER': os.environ.get('DB_USER', 'dbadmin'),
        'PASSWORD': os.environ.get('DB_PASSWORD', ''),
        'HOST': os.environ.get('DB_HOST', 'localhost'),
        'PORT': '3306',
        'OPTIONS': {
            'connect_timeout': 5,
            'read_timeout': 30,
            'write_timeout': 30,
        },
    }
}

INSTALLED_APPS += ['myapp', 'health_check', 'health_check.db']

STATIC_URL = '/static/'
STATIC_ROOT = '/opt/django-app/staticfiles'
MIDDLEWARE.insert(1, 'whitenoise.middleware.WhiteNoiseMiddleware')
STATICFILES_STORAGE = 'whitenoise.storage.CompressedManifestStaticFilesStorage'

SECURE_BROWSER_XSS_FILTER = True
SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = 'DENY'
CSRF_COOKIE_SECURE = False
SESSION_COOKIE_SECURE = False

LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'handlers': {
        'console': {'class': 'logging.StreamHandler'},
        'file': {
            'class': 'logging.FileHandler',
            'filename': '/var/log/django/app.log',
        },
    },
    'root': {
        'handlers': ['console', 'file'],
        'level': 'INFO',
    },
}
SETTINGS

# --- Health check URL ---
cat > "$APP_DIR/config/urls_prod.py" << 'URLS'
from django.contrib import admin
from django.urls import path, include

urlpatterns = [
    path('admin/', admin.site.urls),
    path('health/', include('health_check.urls')),
    path('', include('myapp.urls')),
]
URLS

# --- Create app views ---
mkdir -p "$APP_DIR/myapp/templates/myapp"

cat > "$APP_DIR/myapp/urls.py" << 'APPURLS'
from django.urls import path
from . import views

urlpatterns = [
    path('', views.index, name='index'),
]
APPURLS

cat > "$APP_DIR/myapp/views.py" << 'VIEWS'
import socket
from django.shortcuts import render
from django.http import JsonResponse

def index(request):
    context = {
        'hostname': socket.gethostname(),
    }
    return render(request, 'myapp/index.html', context)
VIEWS

cat > "$APP_DIR/myapp/templates/myapp/index.html" << 'HTML'
<!DOCTYPE html>
<html>
<head><title>AWS 3-Tier App</title></head>
<body>
  <h1>AWS 3-Tier Architecture — Django App</h1>
  <p>Hostname: {{ hostname }}</p>
  <p>Status: Running</p>
</body>
</html>
HTML

# --- Environment variables ---
cat > /etc/django.env << ENVFILE
DB_HOST=${db_host}
DB_NAME=${db_name}
DB_USER=${db_username}
DB_PASSWORD=${db_password}
DJANGO_SETTINGS_MODULE=config.settings_prod
ENVFILE

# --- Log directory ---
mkdir -p /var/log/django
chown -R appuser:appuser /var/log/django
chown -R appuser:appuser "$APP_DIR"

# --- Run migrations ---
export DB_HOST="${db_host}"
export DB_NAME="${db_name}"
export DB_USER="${db_username}"
export DB_PASSWORD="${db_password}"
export DJANGO_SETTINGS_MODULE="config.settings_prod"

cp config/urls_prod.py config/urls.py

python manage.py collectstatic --noinput || true
python manage.py migrate --noinput || true

# --- Systemd service ---
cat > /etc/systemd/system/django.service << 'SERVICE'
[Unit]
Description=Django Application (Gunicorn)
After=network.target

[Service]
User=appuser
Group=appuser
WorkingDirectory=/opt/django-app
EnvironmentFile=/etc/django.env
ExecStart=/opt/django-app/venv/bin/gunicorn config.wsgi:application \
    --bind 0.0.0.0:8000 \
    --workers 3 \
    --timeout 120 \
    --access-logfile /var/log/django/access.log \
    --error-logfile /var/log/django/error.log
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable django
systemctl start django

echo "=== User data script completed at $(date) ==="
