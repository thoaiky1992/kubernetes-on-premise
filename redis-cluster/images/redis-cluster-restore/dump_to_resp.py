#!/usr/bin/env python3
# Đọc một Redis đã nạp dump.rdb (cùng phiên bản 7.0.15 với cluster) và in ra lệnh RESTORE dạng RESP.
# Output dùng cho `redis-cli --pipe`. Script chỉ đọc nguồn, không ghi gì ra ngoài trừ stdout.
# Image restore gọi script với <host> <port>; stdout được lưu thành shard-01.resp.
import sys

import redis


def resp(*args):
    out = [b"*%d\r\n" % len(args)]
    for arg in args:
        if isinstance(arg, str):
            arg = arg.encode()
        out.append(b"$%d\r\n%s\r\n" % (len(arg), arg))
    return b"".join(out)


def main():
    host, port = sys.argv[1], int(sys.argv[2])
    source = redis.Redis(host=host, port=port)
    written = skipped = 0
    for key in source.scan_iter(count=1000):
        ttl = source.pttl(key)
        if ttl == -2:  # key đã hết hạn lúc đọc
            skipped += 1
            continue
        ttl = 0 if ttl == -1 else ttl  # 0 nghĩa là không hết hạn
        payload = source.dump(key)
        sys.stdout.buffer.write(resp(b"RESTORE", key, str(ttl), payload, b"REPLACE"))
        written += 1
    sys.stderr.write(f"written={written} skipped_expired={skipped}\n")


if __name__ == "__main__":
    main()
