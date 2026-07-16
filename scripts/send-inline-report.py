#!/usr/bin/env python3
"""Send a PNG report as an inline CID image using an existing SMTP helper."""

from __future__ import annotations

import argparse
import importlib.util
import sys
from email.message import EmailMessage
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mailer", type=Path, required=True)
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--to", required=True)
    parser.add_argument("--subject", required=True)
    parser.add_argument("--body", required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def load_mailer(path: Path):
    spec = importlib.util.spec_from_file_location("local_smtp_mailer", str(path))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"无法加载 SMTP 工具: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    args = parse_args()
    mailer = load_mailer(args.mailer)
    config = mailer.load_config(args.env_file)

    message = EmailMessage()
    message["From"] = config.sender
    message["To"] = args.to
    message["Subject"] = args.subject
    message.set_content(args.body + "\n\n如果邮件客户端不支持 HTML，请查看内嵌图片部分。")
    message.add_alternative(
        "<html><body>"
        f"<p>{args.body}</p>"
        '<p><img src="cid:codex-token-report" alt="Codex Token 使用报告" '
        'style="display:block;max-width:100%;height:auto"></p>'
        "</body></html>",
        subtype="html",
    )
    html_part = message.get_payload()[1]
    html_part.add_related(
        args.image.read_bytes(),
        maintype="image",
        subtype="png",
        cid="<codex-token-report>",
        filename=args.image.name,
        disposition="inline",
    )

    if args.dry_run:
        print(f"From: {message['From']}")
        print(f"To: {message['To']}")
        print(f"Subject: {message['Subject']}")
        for part in message.walk():
            if part.get_content_maintype() == "multipart":
                continue
            print(
                "Part:",
                part.get_content_type(),
                f"disposition={part.get_content_disposition()}",
                f"cid={part.get('Content-ID', '-')}",
            )
        print("Dry run: no email was sent.", file=sys.stderr)
        return 0
    mailer.send_message(config, message, [args.to])
    print(f"Inline report email sent to {args.to}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
