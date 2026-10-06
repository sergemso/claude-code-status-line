import { test, expect } from 'claude-code/testing'
import { splitArgs } from './args'

test('splits plain words', () => {
  expect(splitArgs('model opus')).toEqual(['model', 'opus'])
})
test('keeps quoted phrases together', () => {
  expect(splitArgs('model "Claude Opus 5.5" x')).toEqual(['model', 'Claude Opus 5.5', 'x'])
})
test('empty input gives no words', () => {
  expect(splitArgs('   ')).toEqual([])
})
