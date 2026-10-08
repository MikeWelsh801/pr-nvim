import time

def fetch(url, retries=3):
    for i in range(retries):
        try:
            return get(url)
        except Error:
            time.sleep(1)
    raise RuntimeError('gave up')

def main():
    print(fetch('x'))
