<?hh // strict
/**
 * Copyright (c) 2014, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 */

function takes_int(int $a): void {}

function takes_string(string $a): void {}

async function bar(): AsyncKeyedIterator<int, (int, string)> {
  yield 1 => tuple(1, "a");
}

async function test(): Awaitable<void> {
  foreach (bar() await as $k => list($x, $y)) {
    takes_int($x);
    takes_string($y);
  }
}
